// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
contract ComposableCowPoller {
    /// @notice Parameters for a JIT funding schedule.
    /// @dev A schedule is uniquely identified by its funder, handler, owner, and salt.
    struct Schedule {
        IConditionalOrderGenerator handler; // the conditional-order handler to poll (e.g. the TWAP type)
        address funder; // source of funds; the only registrant
        address owner; // order owner; the pull destination
        bytes32 salt; // the conditional order's salt
        bytes staticInput; // the order's staticInput
    }

    /// @dev Keyed by `id == scheduleId(funder, handler, owner, salt)`, which is independent of the
    ///      order's `appData`.
    mapping(bytes32 => Schedule) public schedules;

    /// @notice Thrown when someone other than the schedule funder registers or updates a schedule.
    error OnlyFunder();

    /// @notice Emitted when a schedule is registered or updated.
    /// @param id The deterministic key of the schedule.
    /// @param owner The conditional-order owner and pull destination.
    /// @param funder The token source that registered the schedule.
    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Computes the deterministic, appData-independent schedule key.
    /// @dev `staticInput` is excluded because its appData can depend on this key.
    ///      Use a different salt for concurrent schedules with the same funder, handler, and owner.
    /// @param funder The token source.
    /// @param handler The conditional-order generator.
    /// @param owner The conditional-order owner.
    /// @param salt The conditional-order salt.
    /// @return The schedule key.
    function scheduleId(address funder, IConditionalOrderGenerator handler, address owner, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(funder, handler, owner, salt));
    }

    /// @notice Registers or updates a schedule.
    /// @dev Registering the same funder, handler, owner, and salt replaces the stored schedule.
    ///      Only the funds source may register, and the ID is namespaced by the funder.
    /// @param schedule The schedule to store.
    /// @return id The deterministic key of the stored schedule.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        id = scheduleId(schedule.funder, schedule.handler, schedule.owner, schedule.salt);
        schedules[id] = schedule;
        emit ScheduleRegistered(id, schedule.owner, schedule.funder);
    }
}
