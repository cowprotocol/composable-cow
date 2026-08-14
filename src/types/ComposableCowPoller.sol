// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2SafeERC20} from "cowprotocol/contracts/libraries/GPv2SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ComposableCoW} from "src/ComposableCoW.sol";
import {IConditionalOrder, IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

/// @notice The subset of the CowShed factory this contract relies on.
/// @dev `proxyOf` is a pure `CREATE2` derivation over the factory's own immutables, so it cannot be
///      poisoned. The factory's `ownerOf` registry is deliberately not used: it is mutable, and
///      factory subclasses that deploy proxies with a caller-chosen trusted executor write to it.
interface ICowShedFactory {
    function proxyOf(address owner) external view returns (address);
}

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
contract ComposableCowPoller is EIP712 {
    using GPv2SafeERC20 for IERC20;

    /// @dev EIP-712 ScheduleRegistration struct typehash.
    bytes32 public constant SCHEDULE_REGISTRATION_TYPEHASH = keccak256(
        "ScheduleRegistration(address handler,uint96 authEpoch,address funder,address owner,bytes32 salt,bytes staticInput,uint256 deadline)"
    );

    /// @dev EIP-712 Revoke struct typehash.
    bytes32 public constant REVOKE_TYPEHASH =
        keccak256("Revoke(address handler,uint96 authEpoch,address funder,address owner,bytes32 salt,uint256 deadline)");

    /// @dev `ComposableCoW` stores the settlement domain separator supplied at deployment.
    ComposableCoW public immutable COMPOSABLE_COW;

    /// @notice The one CowShed factory whose proxies may manage schedules for their own owner.
    /// @dev Pinned at deployment. It must be a factory whose only deployment path derives the proxy
    ///      from the owner alone, so that a call from `proxyOf(funder)` proves `funder` authorised
    ///      it. See `registerForFunder`.
    ICowShedFactory public immutable COW_SHED_FACTORY;

    /// @notice Parameters for a JIT funding schedule.
    /// @dev `handler`, `salt` and `staticInput` are the order's `ConditionalOrderParams` and must
    ///      match it exactly, since `paramsHash` is derived from them. The schedule key is `funder`,
    ///      `handler`, `owner`, and `salt`.
    struct Schedule {
        /// @notice The conditional-order handler to poll, such as the TWAP type.
        IConditionalOrderGenerator handler;
        /// @notice The authorization epoch for this schedule ID.
        /// @dev Starts at zero. When registering, the supplied epoch must match the epoch stored for
        ///      the schedule ID. Revocation increments it, allowing the same ID to be reused while
        ///      invalidating signatures from prior epochs.
        uint96 authEpoch;
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

    /// @dev Keyed by `id == scheduleId(schedule)`. The key excludes `authEpoch` and `staticInput`,
    ///      so it remains stable when a revoked ID is reused. A nonzero `funder` marks an active
    ///      schedule. Revocation clears it and increments `authEpoch` to invalidate authorizations
    ///      from an earlier epoch.
    mapping(bytes32 => Schedule) public schedules;

    /// @dev `id => orderDigest => funded`. History survives schedule updates so an old order cannot be replayed.
    mapping(bytes32 => mapping(bytes32 => bool)) public funded;

    /// @notice Thrown when someone other than the schedule funder registers, updates, or revokes a schedule.
    error OnlyFunder();

    /// @notice Thrown when a `ForFunder` action does not come from the funder's own CowShed, or when
    ///         that shed tries to register a schedule that funds somebody else.
    error UnauthorizedShed();

    /// @notice Thrown when the CowShed factory supplied at deployment has no code.
    error InvalidCowShedFactory();

    /// @notice Thrown when registering a schedule whose key is already taken. Revoke it first to
    ///         replace it deliberately.
    error AlreadyRegistered();

    /// @notice Thrown when a schedule's authorization epoch does not match the stored epoch.
    error InvalidAuthEpoch();

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

    /// @notice Emitted when a schedule is registered or updated.
    /// @param id The deterministic key of the schedule.
    /// @param owner The conditional-order owner and pull destination.
    /// @param funder The token source that registered the schedule.
    /// @param authEpoch The schedule's authorization epoch.
    /// @param paramsHash The ComposableCoW order key this schedule funds. `id` deliberately excludes
    ///        `staticInput`, so re-registering the same funder, handler, owner, and salt replaces
    ///        the stored schedule. Logging the hash names the order each registration points at,
    ///        which is what makes such a replacement visible off-chain.
    event ScheduleRegistered(
        bytes32 indexed id, address indexed owner, address indexed funder, uint96 authEpoch, bytes32 paramsHash
    );

    /// @notice Emitted when a part's funds are moved.
    /// @dev `orderDigest` is indexed so a single leg can be looked up directly, rather than only
    ///      by walking a schedule's history. It is the CoW order struct hash, so it joins to
    ///      settlement data.
    /// @param id The deterministic key of the schedule.
    /// @param orderDigest The digest of the order that was funded.
    /// @param amount The `sellAmount` moved from the funder to the owner.
    event Pulled(bytes32 indexed id, bytes32 indexed orderDigest, uint256 amount);

    constructor(ComposableCoW _composableCow, ICowShedFactory _cowShedFactory)
        EIP712("ComposableCowPoller", "1")
    {
        // A code-less factory would make every `ForFunder` call revert without saying why.
        if (address(_cowShedFactory).code.length == 0) revert InvalidCowShedFactory();
        COMPOSABLE_COW = _composableCow;
        COW_SHED_FACTORY = _cowShedFactory;
    }

    /// @notice Emitted when a schedule is revoked.
    /// @param id The deterministic key of the revoked schedule.
    /// @param owner The conditional-order owner that was the pull destination.
    /// @param funder The token source that revoked the schedule.
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Returns the EIP-712 domain separator used to authorize registrations.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Computes the deterministic, appData-independent schedule key.
    /// @dev `authEpoch` is excluded so the same key survives revocation. `staticInput` is excluded
    ///      because its appData can depend on this key, which is why a fresh `salt` per order keeps
    ///      distinct orders on distinct keys.
    /// @param schedule The schedule whose identity fields determine the key.
    /// @return The schedule key.
    function scheduleId(Schedule memory schedule) public pure returns (bytes32) {
        return _scheduleId(schedule.funder, schedule.handler, schedule.owner, schedule.salt);
    }

    /// @notice Registers a schedule.
    /// @dev Only the funder may register. Reverts if the schedule is active or its `authEpoch` does
    ///      not match storage. After revocation, the same ID can be registered in the next epoch.
    /// @param schedule The schedule to store.
    /// @return id The deterministic key of the stored schedule.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        return _register(schedule);
    }

    /// @notice Registers a schedule authorized by the funder's EIP-712 signature.
    /// @dev Any caller may submit the signature before its deadline. The signed `authEpoch` must
    ///      match storage, so revocation invalidates signatures from prior epochs.
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
                SCHEDULE_REGISTRATION_TYPEHASH,
                schedule.handler,
                schedule.authEpoch,
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

    /// @notice Registers a schedule for a funder, called by that funder's own CowShed.
    /// @dev Saves the funder a signature: a shed only executes calls its owner authorized, so a call
    ///      from `COW_SHED_FACTORY.proxyOf(funder)` already carries the funder's authorization. The
    ///      ID stays namespaced by `funder`, never by the shed, so the funder keeps unilateral
    ///      `revoke` over whatever its shed registered.
    ///
    ///      `owner` is pinned to the calling shed, so a shed can only fund itself. That is defence in
    ///      depth rather than a boundary — the same signed bundle could name a hostile `receiver`
    ///      inside `staticInput` — but it stops a mis-signed bundle from moving the funder's tokens
    ///      straight to an arbitrary address.
    /// @param schedule The schedule to store. Its `owner` must be the calling shed.
    /// @return id The deterministic key of the stored schedule.
    function registerFromShed(Schedule calldata schedule) external returns (bytes32 id) {
        _requireFunderShed(schedule.funder);
        if (schedule.owner != msg.sender) revert UnauthorizedShed();
        return _register(schedule);
    }

    /// @dev Rejects overwriting an active schedule because it would make the previous order unfundable.
    ///      Revoke first; funding history is retained to prevent replay.
    ///      A zero owner or handler cannot satisfy `pollFunds`'s `singleOrders` check.
    function _register(ComposableCowPoller.Schedule calldata schedule) internal returns (bytes32 id) {
        id = scheduleId(schedule);
        if (schedules[id].funder != address(0)) revert AlreadyRegistered();
        if (schedule.authEpoch != schedules[id].authEpoch) revert InvalidAuthEpoch();
        schedules[id] = schedule;
        emit ScheduleRegistered(
            id,
            schedule.owner,
            schedule.funder,
            schedule.authEpoch,
            _paramsHash(schedule.handler, schedule.salt, schedule.staticInput)
        );
    }

    /// @notice Revokes a schedule or cancels its current authorization epoch before registration.
    /// @dev Uses `msg.sender` as funder, then clears the schedule and increments its `authEpoch`.
    function revoke(IConditionalOrderGenerator handler, address owner, bytes32 salt) external returns (bytes32 id) {
        id = _scheduleId(msg.sender, handler, owner, salt);
        _revoke(id, msg.sender, owner, schedules[id].authEpoch);
    }

    /// @notice Revokes a schedule or cancels its current authorization epoch with a funder signature.
    /// @dev Any caller may submit a valid signature before its deadline. The supplied `authEpoch`
    ///      must match storage so signatures from earlier epochs cannot be reused.
    /// @param handler The conditional-order handler identifying the schedule.
    /// @param funder The schedule funder whose signature authorizes the revocation.
    /// @param owner The conditional-order owner identifying the schedule.
    /// @param salt The conditional order's salt identifying the schedule.
    /// @param authEpoch The schedule's authorization epoch signed by the funder.
    /// @param deadline The last block timestamp at which the signature is valid.
    /// @param signature The funder's EIP-712 signature.
    function revokeWithSignature(
        IConditionalOrderGenerator handler,
        address funder,
        address owner,
        bytes32 salt,
        uint96 authEpoch,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 id) {
        if (block.timestamp > deadline) revert SignatureExpired();

        id = _scheduleId(funder, handler, owner, salt);
        if (authEpoch != schedules[id].authEpoch) revert InvalidAuthEpoch();
        bytes32 structHash = keccak256(abi.encode(REVOKE_TYPEHASH, handler, authEpoch, funder, owner, salt, deadline));
        if (!SignatureChecker.isValidSignatureNow(funder, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature();
        }

        _revoke(id, funder, owner, authEpoch);
    }

    /// @notice Revoke or pre-emptively cancel a funder's schedule, called by that funder's own
    ///         CowShed.
    /// @dev `funder` is explicit rather than taken from `msg.sender`: the shed is the caller, but the
    ///      ID is namespaced by the funder. Deriving it from `msg.sender` as `revoke` does would
    ///      bump the epoch of an unrelated ID in the shed's own namespace and leave the real
    ///      schedule live.
    function revokeFromShed(IConditionalOrderGenerator handler, address funder, address owner, bytes32 salt)
        external
        returns (bytes32 id)
    {
        _requireFunderShed(funder);

        id = _scheduleId(funder, handler, owner, salt);
        _revoke(id, funder, owner, schedules[id].authEpoch);
    }

    /// @dev Requires the caller to be `funder`'s CowShed, which implies `funder` authorized the call.
    ///      The zero check short-circuits before the external call, and is required regardless:
    ///      `address(0)` is the unregistered-schedule sentinel, and `proxyOf(address(0))` is a real
    ///      derivable address that anyone may deploy a shed to.
    function _requireFunderShed(address funder) internal view {
        if (funder == address(0) || msg.sender != COW_SHED_FACTORY.proxyOf(funder)) revert UnauthorizedShed();
    }

    /// @dev Clears the schedule and increments its `authEpoch`, whether registered or not.
    function _revoke(bytes32 id, address funder, address owner, uint96 authEpoch) internal {
        emit ScheduleRevoked(id, owner, funder);
        delete schedules[id];
        schedules[id].authEpoch = authEpoch + 1;
    }

    /// @dev Derives the funder-namespaced ID, excluding `authEpoch` and `staticInput`.
    function _scheduleId(address funder, IConditionalOrderGenerator handler, address owner, bytes32 salt)
        internal
        pure
        returns (bytes32 id)
    {
        return keccak256(abi.encode(funder, handler, owner, salt));
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
        if (schedule.funder == address(0)) revert NoSchedule();

        // Re-derive the hash on-chain, so `pollFunds(id)` stays independent of the order's `appData`.
        bytes32 paramsHash = _paramsHash(schedule.handler, schedule.salt, schedule.staticInput);

        // The order must still be authorised; `remove` disables the poller.
        if (!COMPOSABLE_COW.singleOrders(schedule.owner, paramsHash)) revert OrderNotLive();

        // The handler yields the current order and reverts outside its window.
        GPv2Order.Data memory order = schedule.handler.getTradeableOrder(
            schedule.owner, address(this), paramsHash, schedule.staticInput, bytes("")
        );

        // `ComposableCoW` exposes the settlement domain separator it received at deployment.
        bytes32 orderDigest = GPv2Order.hash(order, COMPOSABLE_COW.domainSeparator());
        if (funded[id][orderDigest]) return false;
        funded[id][orderDigest] = true;

        order.sellToken.safeTransferFrom(schedule.funder, schedule.owner, order.sellAmount);
        emit Pulled(id, orderDigest, order.sellAmount);
        return true;
    }
}
