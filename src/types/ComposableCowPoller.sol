// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IConditionalOrderGenerator} from "../interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
contract ComposableCowPoller {
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

    error OnlyFunder();

    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder);

    /// @notice Deterministic, appData-independent schedule key.
    function scheduleId(address funder, IConditionalOrderGenerator handler, address owner, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(funder, handler, owner, salt));
    }

    /// @notice Register or update a schedule. Only the funds source may register, and the `id` is
    ///         namespaced by `funder`.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        id = scheduleId(schedule.funder, schedule.handler, schedule.owner, schedule.salt);
        schedules[id] = schedule;
        emit ScheduleRegistered(id, schedule.owner, schedule.funder);
    }
}
