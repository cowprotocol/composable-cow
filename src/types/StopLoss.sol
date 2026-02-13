// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {
    IERC20,
    GPv2Order,
    IConditionalOrder,
    IConditionalOrderGenerator,
    BaseConditionalOrder
} from "../BaseConditionalOrder.sol";
import {IOrderManifest} from "../interfaces/IOrderManifest.sol";
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

    // ============ IOrderManifest Override ============

    /// @inheritdoc IOrderManifest
    /// @dev Custom implementation that shows order structure even when strike not reached
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        uint256 offset,
        uint256 limit
    ) external view override returns (ManifestEntry[] memory entries, bool hasMore) {
        // Single-shot: only index 0 exists
        if (offset > 0 || limit == 0) {
            return (new ManifestEntry[](0), false);
        }

        Data memory data = abi.decode(staticInput, (Data));

        // Check if order has expired
        if (data.validTo < block.timestamp) {
            return (new ManifestEntry[](0), false);
        }

        // Build the order structure (without condition checks)
        GPv2Order.Data memory order = GPv2Order.Data(
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

        // Check if currently active (strike reached and oracles valid)
        bool isActive = _checkStrikeCondition(data);

        entries = new ManifestEntry[](1);
        entries[0] = ManifestEntry({
            index: 0,
            order: order,
            validFrom: 0, // Condition-based, valid immediately when strike hit
            isActive: isActive
        });
        hasMore = false;
    }

    /// @dev Check if strike condition is currently met (without reverting)
    function _checkStrikeCondition(Data memory data) internal view returns (bool) {
        // Check expiry
        if (data.validTo < block.timestamp) {
            return false;
        }

        // Get oracle prices
        try data.sellTokenPriceOracle.latestRoundData() returns (
            uint80, int256 basePrice, uint256, uint256 sellUpdatedAt, uint80
        ) {
            try data.buyTokenPriceOracle.latestRoundData() returns (
                uint80, int256 quotePrice, uint256, uint256 buyUpdatedAt, uint80
            ) {
                // Check price validity
                if (basePrice <= 0 || quotePrice <= 0) {
                    return false;
                }

                // Check staleness
                if (
                    sellUpdatedAt < block.timestamp - data.maxTimeSinceLastOracleUpdate
                        || buyUpdatedAt < block.timestamp - data.maxTimeSinceLastOracleUpdate
                ) {
                    return false;
                }

                // Scale prices and check strike
                int256 scaledBasePrice = Utils.scalePrice(basePrice, data.sellTokenPriceOracle.decimals(), 18);
                int256 scaledQuotePrice = Utils.scalePrice(quotePrice, data.buyTokenPriceOracle.decimals(), 18);

                return scaledBasePrice * SCALING_FACTOR / scaledQuotePrice <= data.strike;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
