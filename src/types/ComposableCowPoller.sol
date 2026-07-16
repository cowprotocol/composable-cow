// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
contract ComposableCowPoller {
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
        /// @dev Use a value unique to the user and order. Deriving it from order-defining static-input values,
        ///      excluding appData, is recommended.
        bytes32 salt;
        /// @notice The static input passed to the handler when it generates an order.
        bytes staticInput;
    }

    /// @dev Keyed by `id == scheduleId(schedule)`, which excludes the order's `appData`.
    mapping(bytes32 => Schedule) public schedules;

    /// @notice Thrown when someone other than the schedule funder registers or updates a schedule.
    error OnlyFunder();

    /// @notice Emitted when a schedule is registered or updated.
    /// @param id The deterministic key of the schedule.
    /// @param owner The conditional-order owner and pull destination.
    /// @param funder The token source that registered the schedule.
    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Emitted when a schedule is revoked.
    /// @param id The deterministic key of the revoked schedule.
    /// @param owner The conditional-order owner that was the pull destination.
    /// @param funder The token source that revoked the schedule.
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Computes the deterministic, appData-independent schedule key.
    /// @dev `staticInput` is excluded because its appData can depend on this key.
    ///      Use a different salt for concurrent schedules with the same funder, handler, and owner.
    /// @param schedule The schedule whose identity fields determine the key.
    /// @return The schedule key.
    function scheduleId(Schedule memory schedule) public pure returns (bytes32) {
        return keccak256(abi.encode(schedule.funder, schedule.handler, schedule.owner, schedule.salt));
    }

    /// @notice Registers or updates a schedule.
    /// @dev Registering the same funder, handler, owner, and salt replaces the stored schedule.
    ///      Only the funds source may register, and the ID is namespaced by the funder.
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
}
