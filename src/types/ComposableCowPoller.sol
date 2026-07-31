// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2SafeERC20} from "cowprotocol/contracts/libraries/GPv2SafeERC20.sol";

import {ComposableCoW} from "src/ComposableCoW.sol";
import {IConditionalOrder, IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
contract ComposableCowPoller {
    using GPv2SafeERC20 for IERC20;

    /// @dev `ComposableCoW` stores the settlement domain separator supplied at deployment.
    ComposableCoW public immutable COMPOSABLE_COW;

    /// @notice Parameters for a JIT funding schedule.
    /// @dev A schedule is uniquely identified by its funder, handler, owner, and salt.
    struct Schedule {
        /// @notice The conditional-order handler to poll, such as the TWAP type.
        IConditionalOrderGenerator handler;
        /// @notice The address allowed to register this schedule and later debited for sell tokens.
        /// @dev It can be an EOA or contract and may be the same address as `owner`.
        address funder;
        /// @notice The address that owns the ComposableCoW conditional order and receives the pulled funds.
        /// @dev It can be an EOA or contract and may be the same address as `funder`.
        address owner;
        /// @notice A user-controlled namespace for this schedule.
        /// @dev Keep it unique to the user and logical order. A good default is the hash of the
        ///      order-defining static-input values with any appData field set to zero.
        bytes32 salt;
        /// @notice The static input passed to the handler when it generates an order.
        bytes staticInput;
    }

    /// @dev Keyed by `id == scheduleId(schedule)`, which excludes the order's `appData`.
    mapping(bytes32 => Schedule) public schedules;

    /// @dev `id => orderDigest => funded`. History survives schedule updates so an old order cannot be replayed.
    mapping(bytes32 => mapping(bytes32 => bool)) public funded;

    /// @notice Thrown when someone other than the schedule funder registers, updates, or revokes a schedule.
    error OnlyFunder();

    /// @notice Thrown when polling an ID that has no registered schedule, because it was never
    ///         registered or has since been revoked.
    error NoSchedule();

    /// @notice Thrown when the schedule's conditional order is not authorised in `ComposableCoW`,
    ///         either because it was never created or because it was removed.
    error OrderNotLive();

    /// @notice Emitted when a schedule is registered or updated.
    /// @param id The deterministic key of the schedule.
    /// @param owner The conditional-order owner and pull destination.
    /// @param funder The token source that registered the schedule.
    /// @param paramsHash The ComposableCoW order key this schedule funds. `id` deliberately excludes
    ///        `staticInput`, so re-registering the same funder, handler, owner, and salt replaces
    ///        the stored schedule. Logging the hash names the order each registration points at,
    ///        which is what makes such a replacement visible off-chain.
    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder, bytes32 paramsHash);

    /// @notice Emitted when an order's sell amount is moved from the funder to the owner.
    /// @param id The deterministic key of the schedule that was polled.
    /// @param orderDigest The EIP-712 digest of the funded order, unique per part of the schedule.
    /// @param amount The amount of `sellToken` transferred.
    event Pulled(bytes32 indexed id, bytes32 orderDigest, uint256 amount);

    constructor(ComposableCoW _composableCow) {
        COMPOSABLE_COW = _composableCow;
    }

    /// @notice Emitted when a schedule is revoked.
    /// @param id The deterministic key of the revoked schedule.
    /// @param owner The conditional-order owner that was the pull destination.
    /// @param funder The token source that revoked the schedule.
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Computes the deterministic, appData-independent schedule key.
    /// @dev `staticInput` is excluded because its appData can depend on this key.
    ///      Keep the salt unique to the user and logical order. A good default is the hash of the
    ///      order-defining static-input values with any appData field set to zero.
    /// @param schedule The schedule whose identity fields determine the key.
    /// @return The schedule key.
    function scheduleId(Schedule memory schedule) public pure returns (bytes32) {
        return keccak256(abi.encode(schedule.funder, schedule.handler, schedule.owner, schedule.salt));
    }

    /// @notice Registers or updates a schedule.
    /// @dev Registering the same funder, handler, owner, and salt replaces the stored schedule.
    ///      Only the funds source may register, and the ID is namespaced by the funder. Funding
    ///      history is preserved across updates; use a new salt for a new logical schedule.
    ///      A zero `owner` or `handler` needs no check: `pollFunds` requires
    ///      `singleOrders[owner][paramsHash]`, which neither can ever satisfy.
    /// @param schedule The schedule to store.
    /// @return id The deterministic key of the stored schedule.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        id = scheduleId(schedule);
        schedules[id] = schedule;
        emit ScheduleRegistered(
            id, schedule.owner, schedule.funder, _paramsHash(schedule.handler, schedule.salt, schedule.staticInput)
        );
    }

    /// @notice Revoke a schedule. Only the funds source may do so. A standing ERC-20 allowance
    ///         should be revoked separately to fully close the surface.
    function revoke(bytes32 id) external {
        Schedule storage schedule = schedules[id];
        if (msg.sender != schedule.funder) revert OnlyFunder();
        emit ScheduleRevoked(id, schedule.owner, schedule.funder);
        delete schedules[id];
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
    function pollFunds(bytes32 id) external {
        Schedule memory schedule = schedules[id];
        if (schedule.funder == address(0)) revert NoSchedule();

        // Re-derive the hash on-chain, so `pollFunds(id)` stays independent of the order's `appData`.
        bytes32 paramsHash = _paramsHash(schedule.handler, schedule.salt, schedule.staticInput);

        // The order must still be authorised; `remove` disables the poller.
        if (!COMPOSABLE_COW.singleOrders(schedule.owner, paramsHash)) revert OrderNotLive();

        // The handler yields the current order and reverts outside its window.
        GPv2Order.Data memory order = schedule.handler
            .getTradeableOrder(schedule.owner, address(this), paramsHash, schedule.staticInput, bytes(""));

        // `ComposableCoW` exposes the settlement domain separator it received at deployment.
        bytes32 orderDigest = GPv2Order.hash(order, COMPOSABLE_COW.domainSeparator());
        if (funded[id][orderDigest]) return;
        funded[id][orderDigest] = true;

        order.sellToken.safeTransferFrom(schedule.funder, schedule.owner, order.sellAmount);
        emit Pulled(id, orderDigest, order.sellAmount);
    }
}
