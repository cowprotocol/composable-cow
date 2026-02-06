// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order, IConditionalOrder, BaseConditionalOrder} from "../BaseConditionalOrder.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";
import {BALANCE_INSUFFICIENT} from "./GoodAfterTime.sol";

/// @title TradeAboveThreshold - Trades when balance exceeds threshold
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Sells entire balance when it exceeds the specified threshold.
contract TradeAboveThreshold is BaseConditionalOrder {
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint32 validityBucketSeconds;
        uint256 threshold;
        bytes32 appData;
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        Data memory data = abi.decode(staticInput, (Data));

        uint256 balance = data.sellToken.balanceOf(owner);
        require(balance >= data.threshold, IConditionalOrder.PollTryNextBlock(BALANCE_INSUFFICIENT));

        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            balance,
            1,
            Utils.validToBucket(data.validityBucketSeconds),
            data.appData,
            0,
            GPv2Order.KIND_SELL,
            false,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
    // Uses default getNextPollTimestamp() and describeOrder() from BaseConditionalOrder
}
