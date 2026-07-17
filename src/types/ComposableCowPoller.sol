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

    /// @dev `id => digest => funded`. History survives schedule updates so an old order cannot be replayed.
    mapping(bytes32 => mapping(bytes32 => bool)) public funded;

    /// @notice Thrown when someone other than the schedule funder registers or updates a schedule.
    error OnlyFunder();
    error NoSchedule();
    error OrderNotLive();

    /// @notice Emitted when a schedule is registered or updated.
    /// @param id The deterministic key of the schedule.
    /// @param owner The conditional-order owner and pull destination.
    /// @param funder The token source that registered the schedule.
    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder);
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
    /// @param schedule The schedule to store.
    /// @return id The deterministic key of the stored schedule.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        id = scheduleId(schedule);
        schedules[id] = schedule;
        emit ScheduleRegistered(id, schedule.owner, schedule.funder);
    }

    /// @notice Revoke a schedule. Only the funds source may do so. A standing ERC-20 allowance
    ///         should be revoked separately to fully close the surface.
    function revoke(bytes32 id) external {
        Schedule storage schedule = schedules[id];
        if (msg.sender != schedule.funder) revert OnlyFunder();
        emit ScheduleRevoked(id, schedule.owner, schedule.funder);
        delete schedules[id];
    }

    /// @notice Move the current order's `sellAmount` from the funder to the owner. Permissionless.
    ///         The full amount always moves (no balance check), so one owner can serve several
    ///         concurrent orders.
    function pollFunds(bytes32 id) external {
        Schedule memory schedule = schedules[id];
        if (schedule.funder == address(0)) revert NoSchedule();

        // Re-derive `ctx` on-chain, so `pollFunds(id)` stays independent of the order's `appData`.
        bytes32 ctx = COMPOSABLE_COW.hash(
            IConditionalOrder.ConditionalOrderParams({
                handler: schedule.handler, salt: schedule.salt, staticInput: schedule.staticInput
            })
        );

        // The order must still be authorised; `remove` disables the poller.
        if (!COMPOSABLE_COW.singleOrders(schedule.owner, ctx)) revert OrderNotLive();

        // The handler yields the current order and reverts outside its window.
        GPv2Order.Data memory order =
            schedule.handler.getTradeableOrder(schedule.owner, address(this), ctx, schedule.staticInput, bytes(""));

        // `ComposableCoW` exposes the settlement domain separator it received at deployment.
        bytes32 digest = GPv2Order.hash(order, COMPOSABLE_COW.domainSeparator());
        if (funded[id][digest]) return;
        funded[id][digest] = true;

        order.sellToken.safeTransferFrom(schedule.funder, schedule.owner, order.sellAmount);
        emit Pulled(id, digest, order.sellAmount);
    }
}
