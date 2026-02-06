// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {
    IERC20,
    GPv2Order,
    IConditionalOrder,
    IConditionalOrderGenerator,
    BaseConditionalOrder
} from "../BaseConditionalOrder.sol";
import {IAggregatorV3Interface} from "../interfaces/IAggregatorV3Interface.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

string constant STRIKE_NOT_REACHED = "strike not reached";
string constant ORACLE_STALE_PRICE = "oracle stale price";
string constant ORACLE_INVALID_PRICE = "oracle invalid price";
string constant ORDER_EXPIRED = "order expired";

/// @title StopLoss conditional order
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Triggers when sellToken price falls below strike price using Chainlink oracles.
/// @dev Both oracles must be denominated in the same quote currency.
contract StopLoss is BaseConditionalOrder {
    int256 constant SCALING_FACTOR = 10 ** 18;

    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        bytes32 appData;
        address receiver;
        bool isSellOrder;
        bool isPartiallyFillable;
        uint32 validTo;
        IAggregatorV3Interface sellTokenPriceOracle;
        IAggregatorV3Interface buyTokenPriceOracle;
        int256 strike;
        uint256 maxTimeSinceLastOracleUpdate;
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(address, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        Data memory data = abi.decode(staticInput, (Data));

        {
            require(data.validTo >= block.timestamp, IConditionalOrder.OrderNotValid(ORDER_EXPIRED));

            (, int256 basePrice,, uint256 sellUpdatedAt,) = data.sellTokenPriceOracle.latestRoundData();
            (, int256 quotePrice,, uint256 buyUpdatedAt,) = data.buyTokenPriceOracle.latestRoundData();

            require(basePrice > 0 && quotePrice > 0, IConditionalOrder.OrderNotValid(ORACLE_INVALID_PRICE));

            require(
                sellUpdatedAt >= block.timestamp - data.maxTimeSinceLastOracleUpdate
                    && buyUpdatedAt >= block.timestamp - data.maxTimeSinceLastOracleUpdate,
                IConditionalOrder.PollTryNextBlock(ORACLE_STALE_PRICE)
            );

            basePrice = Utils.scalePrice(basePrice, data.sellTokenPriceOracle.decimals(), 18);
            quotePrice = Utils.scalePrice(quotePrice, data.buyTokenPriceOracle.decimals(), 18);

            require(
                basePrice * SCALING_FACTOR / quotePrice <= data.strike,
                IConditionalOrder.PollTryNextBlock(STRIKE_NOT_REACHED)
            );
        }

        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            data.sellAmount,
            data.buyAmount,
            data.validTo,
            data.appData,
            0,
            data.isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            data.isPartiallyFillable,
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
        return POLL_NEVER; // Single-shot order
    }

    /// @inheritdoc IConditionalOrderGenerator
    function describeOrder(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        pure
        override
        returns (string memory)
    {
        return "stop-loss triggered";
    }
}
