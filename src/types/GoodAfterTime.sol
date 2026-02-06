// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IExpectedOutCalculator} from "../vendored/Milkman.sol";
import {
    IERC20,
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    BaseConditionalOrder
} from "../BaseConditionalOrder.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

string constant TOO_EARLY = "too early";
string constant BALANCE_INSUFFICIENT = "balance insufficient";
string constant PRICE_CHECKER_FAILED = "price checker failed";

/// @title Good After Time (GAT) Conditional Order
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Order valid after a certain time with optional Milkman price checking.
contract GoodAfterTime is BaseConditionalOrder {
    using SafeCast for uint256;

    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 minSellBalance;
        uint256 startTime;
        uint256 endTime;
        bool allowPartialFill;
        bytes priceCheckerPayload;
        bytes32 appData;
    }

    struct PriceCheckerPayload {
        IExpectedOutCalculator checker;
        bytes payload;
        uint256 allowedSlippage;
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata offchainInput)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        Data memory data = abi.decode(staticInput, (Data));

        require(block.timestamp >= data.startTime, IConditionalOrder.PollTryAtTimestamp(data.startTime, TOO_EARLY));

        require(
            data.sellToken.balanceOf(owner) >= data.minSellBalance,
            IConditionalOrder.OrderNotValid(BALANCE_INSUFFICIENT)
        );

        uint256 buyAmount = abi.decode(offchainInput, (uint256));

        if (data.priceCheckerPayload.length > 0) {
            PriceCheckerPayload memory p = abi.decode(data.priceCheckerPayload, (PriceCheckerPayload));
            uint256 _expectedOut = p.checker.getExpectedOut(data.sellAmount, data.sellToken, data.buyToken, p.payload);

            require(
                buyAmount >= (_expectedOut * (Utils.MAX_BPS - p.allowedSlippage)) / Utils.MAX_BPS,
                IConditionalOrder.PollTryNextBlock(PRICE_CHECKER_FAILED)
            );
        }

        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            data.sellAmount,
            buyAmount,
            data.endTime.toUint32(),
            data.appData,
            0,
            GPv2Order.KIND_SELL,
            data.allowPartialFill,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }

    /// @inheritdoc IConditionalOrderGenerator
    function getNextPollTimestamp(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        pure
        override
        returns (uint256)
    {
        return POLL_NEVER; // Single-shot within time window
    }

    /// @inheritdoc IConditionalOrderGenerator
    function describeOrder(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        pure
        override
        returns (string memory)
    {
        return "good-after-time order ready";
    }
}
