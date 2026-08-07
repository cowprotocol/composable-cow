// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2SafeERC20} from "cowprotocol/contracts/libraries/GPv2SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ComposableCoW} from "src/ComposableCoW.sol";
import {IConditionalOrder, IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
contract ComposableCowPoller is EIP712 {
    using GPv2SafeERC20 for IERC20;

    /// @dev EIP-712 Register struct typehash.
    bytes32 private constant REGISTER_TYPEHASH = keccak256(
        "Register(address handler,address funder,address owner,bytes32 salt,bytes32 staticInputHash,uint256 deadline)"
    );

    /// @dev `ComposableCoW` stores the settlement domain separator supplied at deployment.
    ComposableCoW public immutable COMPOSABLE_COW;

    /// @notice Parameters for a JIT funding schedule.
    /// @dev `handler`, `salt` and `staticInput` are the order's `ConditionalOrderParams` and must
    ///      match it exactly, since `paramsHash` is derived from them. The schedule key is `funder`,
    ///      `handler`, `owner`, and `salt`.
    struct Schedule {
        /// @notice The conditional-order handler to poll, such as the TWAP type.
        IConditionalOrderGenerator handler;
        /// @notice The address allowed to register this schedule and later debited for sell tokens.
        /// @dev It can be an EOA or contract and may be the same address as `owner`.
        address funder;
        /// @notice The address that owns the ComposableCoW conditional order and receives the pulled funds.
        /// @dev It can be an EOA or contract and may be the same address as `funder`.
        address owner;
        /// @notice The conditional order's own `salt`.
        /// @dev It is what keeps two otherwise-identical orders distinct in ComposableCoW, so use
        ///      a fresh random value per order.
        bytes32 salt;
        /// @notice The order's `staticInput`, byte-for-byte.
        /// @dev A mismatch is not caught at registration; `pollFunds` reverts `OrderNotLive`.
        bytes staticInput;
    }

    /// @dev Keyed by `id == scheduleId(schedule)`, which excludes the order's `appData`.
    mapping(bytes32 => Schedule) public schedules;

    /// @dev `id => orderDigest => funded`.
    mapping(bytes32 => mapping(bytes32 => bool)) public funded;

    /// @notice Thrown when someone other than the schedule funder registers or revokes a schedule.
    error OnlyFunder();

    /// @notice Thrown when registering a schedule whose key has already been used.
    error AlreadyRegistered();

    /// @notice Thrown when registering a schedule with a zero handler.
    error InvalidHandler();

    /// @notice Thrown when polling an ID that has no registered schedule, because it was never
    ///         registered or has since been revoked.
    error NoSchedule();

    /// @notice Thrown when the schedule's conditional order is not authorised in `ComposableCoW`,
    ///         either because it was never created or because it was removed.
    error OrderNotLive();

    /// @notice Thrown when a signed action is submitted after its deadline.
    error SignatureExpired();

    /// @notice Thrown when a signed action cannot be authenticated by its funder.
    error InvalidSignature();

    /// @notice Emitted when a schedule is registered.
    /// @param id The deterministic key of the schedule.
    /// @param owner The conditional-order owner and pull destination.
    /// @param funder The token source that registered the schedule.
    /// @param paramsHash The ComposableCoW order key this schedule funds.
    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder, bytes32 paramsHash);

    /// @notice Emitted when a part's funds are moved.
    /// @dev `orderDigest` is indexed so a single leg can be looked up directly, rather than only
    ///      by walking a schedule's history. It is the CoW order struct hash, so it joins to
    ///      settlement data.
    /// @param id The deterministic key of the schedule.
    /// @param orderDigest The digest of the order that was funded.
    /// @param amount The `sellAmount` moved from the funder to the owner.
    event Pulled(bytes32 indexed id, bytes32 indexed orderDigest, uint256 amount);

    constructor(ComposableCoW _composableCow) EIP712("ComposableCowPoller", "1") {
        COMPOSABLE_COW = _composableCow;
    }

    /// @notice Emitted when a schedule is revoked.
    /// @param id The deterministic key of the revoked schedule.
    /// @param owner The conditional-order owner that was the pull destination.
    /// @param funder The token source that revoked the schedule.
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Computes the deterministic, appData-independent schedule key.
    /// @dev `staticInput` is excluded because its appData can depend on this key, which is why a
    ///      fresh `salt` per order is what keeps distinct orders on distinct keys.
    /// @param schedule The schedule whose identity fields determine the key.
    /// @return The schedule key.
    function scheduleId(Schedule memory schedule) public pure returns (bytes32) {
        return keccak256(abi.encode(schedule.funder, schedule.handler, schedule.owner, schedule.salt));
    }

    /// @notice Registers a schedule.
    /// @dev Reverts if the key has ever been used. The key ignores `staticInput`, so a fresh `salt`
    ///      is required to register another order, including after revocation.
    ///      Only the funds source may register, and the ID is namespaced by the funder.
    ///      A zero `owner` needs no check: `pollFunds` requires `singleOrders[owner][paramsHash]`,
    ///      which it can never satisfy.
    /// @param schedule The schedule to store.
    /// @return id The deterministic key of the stored schedule.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        return _register(schedule);
    }

    /// @notice Registers a schedule authorized by the funder's EIP-712 signature.
    /// @dev Any caller may submit the signature before its deadline.
    /// @param schedule The schedule to store.
    /// @param deadline The last block timestamp at which the signature is valid.
    /// @param signature The funder's EIP-712 signature.
    /// @return id The deterministic key of the stored schedule.
    function registerWithSignature(Schedule calldata schedule, uint256 deadline, bytes calldata signature)
        external
        returns (bytes32 id)
    {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(
            abi.encode(
                REGISTER_TYPEHASH,
                schedule.handler,
                schedule.funder,
                schedule.owner,
                schedule.salt,
                keccak256(schedule.staticInput),
                deadline
            )
        );
        if (!SignatureChecker.isValidSignatureNow(schedule.funder, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }

        return _register(schedule);
    }

    /// @dev Stores a schedule and permanently marks its ID as used.
    function _register(ComposableCowPoller.Schedule calldata schedule) internal returns (bytes32 id) {
        if (address(schedule.handler) == address(0)) revert InvalidHandler();
        id = scheduleId(schedule);
        if (schedules[id].funder != address(0)) revert AlreadyRegistered();
        schedules[id] = schedule;
        emit ScheduleRegistered(
            id, schedule.owner, schedule.funder, _paramsHash(schedule.handler, schedule.salt, schedule.staticInput)
        );
    }

    /// @notice Revoke a schedule. Only the funds source may do so. A standing ERC-20 allowance
    ///         should be revoked separately to fully close the surface.
    function revoke(bytes32 id) external {
        Schedule storage schedule = schedules[id];
        if (address(schedule.handler) == address(0)) revert NoSchedule();
        if (msg.sender != schedule.funder) revert OnlyFunder();
        emit ScheduleRevoked(id, schedule.owner, schedule.funder);
        delete schedule.handler;
        delete schedule.owner;
        delete schedule.salt;
        delete schedule.staticInput;
    }

    /// @notice Hashes a schedule's `ConditionalOrderParams`, which is the order key it funds.
    /// @dev Mirrors `ComposableCoW.hash(params)` rather than calling it: the value is identical,
    ///      and deriving it here avoids re-encoding `staticInput` as calldata for an external
    ///      call. The equivalence is exercised by the `pollFunds` tests, which revert
    ///      `OrderNotLive` if the derived key does not match the authorised order.
    /// @return The params hash. `ComposableCoW` calls this the order's `ctx`, though only for
    ///         single orders: under a merkle root its `ctx` is zero. The poller only funds single
    ///         orders, so the two always coincide here.
    function _paramsHash(IConditionalOrderGenerator handler, bytes32 salt, bytes memory staticInput)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                IConditionalOrder.ConditionalOrderParams({handler: handler, salt: salt, staticInput: staticInput})
            )
        );
    }

    /// @notice Move the current order's `sellAmount` from the funder to the owner. Permissionless.
    ///         The full amount always moves (no balance check), so one owner can serve several
    ///         concurrent orders.
    /// @return Whether funds moved. `false` means this order was already funded, which is the one
    ///         outcome a caller cannot otherwise tell apart from a transfer without diffing
    ///         balances; every other case reverts.
    function pollFunds(bytes32 id) external returns (bool) {
        Schedule memory schedule = schedules[id];
        if (address(schedule.handler) == address(0)) revert NoSchedule();

        // Re-derive the hash on-chain, so `pollFunds(id)` stays independent of the order's `appData`.
        bytes32 paramsHash = _paramsHash(schedule.handler, schedule.salt, schedule.staticInput);

        // The order must still be authorised; `remove` disables the poller.
        if (!COMPOSABLE_COW.singleOrders(schedule.owner, paramsHash)) revert OrderNotLive();

        // The handler yields the current order and reverts outside its window.
        GPv2Order.Data memory order = schedule.handler
            .getTradeableOrder(schedule.owner, address(this), paramsHash, schedule.staticInput, bytes(""));

        // `ComposableCoW` exposes the settlement domain separator it received at deployment.
        bytes32 orderDigest = GPv2Order.hash(order, COMPOSABLE_COW.domainSeparator());
        if (funded[id][orderDigest]) return false;
        funded[id][orderDigest] = true;

        order.sellToken.safeTransferFrom(schedule.funder, schedule.owner, order.sellAmount);
        emit Pulled(id, orderDigest, order.sellAmount);
        return true;
    }
}
