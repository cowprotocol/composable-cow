// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCoW} from "../../ComposableCoW.sol";
import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    BaseConditionalOrder
} from "../../BaseConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";
import {TWAPOrderMathLib, AFTER_TWAP_FINISH} from "./libraries/TWAPOrderMathLib.sol";

string constant NOT_WITHIN_SPAN = "outside span";

/// @title TWAP Conditional Order
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Splits an order into multiple parts executed at fixed intervals.
contract TWAP is BaseConditionalOrder {
    ComposableCoW public immutable composableCow;

    constructor(ComposableCoW _composableCow) {
        composableCow = _composableCow;
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(address owner, address, bytes32 ctx, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        TWAPOrder.Data memory twap = abi.decode(staticInput, (TWAPOrder.Data));

        // Get start time from cabinet if not specified
        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }

        order = TWAPOrder.orderFor(twap);

        // Check if outside the TWAP part's span
        if (block.timestamp > order.validTo) {
            // Calculate next part start time
            uint256 part = TWAPOrderMathLib.currentPart(twap.t0, twap.t);
            uint256 nextPartStart = twap.t0 + ((part + 1) * twap.t);
            uint256 endTime = twap.t0 + (twap.n * twap.t);

            require(nextPartStart < endTime, IConditionalOrder.OrderNotValid(AFTER_TWAP_FINISH));
            revert IConditionalOrder.PollTryAtTimestamp(nextPartStart, NOT_WITHIN_SPAN);
        }
    }

    /// @inheritdoc IConditionalOrderGenerator
    function getNextPollTimestamp(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory)
        external
        view
        override
        returns (uint256)
    {
        TWAPOrder.Data memory twap = abi.decode(staticInput, (TWAPOrder.Data));

        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }

        uint256 part = TWAPOrderMathLib.currentPart(twap.t0, twap.t);

        // Last part - stop polling after this fills
        if (part >= twap.n - 1) {
            return POLL_NEVER;
        }

        // Next part starts at...
        return twap.t0 + ((part + 1) * twap.t);
    }

    /// @inheritdoc IConditionalOrderGenerator
    function describeOrder(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory)
        external
        view
        override
        returns (string memory)
    {
        TWAPOrder.Data memory twap = abi.decode(staticInput, (TWAPOrder.Data));

        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }

        uint256 part = TWAPOrderMathLib.currentPart(twap.t0, twap.t);

        if (part >= twap.n - 1) {
            return "final twap part";
        }
        return "twap part ready";
    }
}
