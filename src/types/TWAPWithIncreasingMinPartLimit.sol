// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCoW} from "../ComposableCoW.sol";

import {
    IERC20,
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    BaseConditionalOrder
} from "../BaseConditionalOrder.sol";
import {TWAPOrder} from "./twap/libraries/TWAPOrder.sol";

// --- error strings

/// @dev The order is not within the TWAP bundle's span.
string constant NOT_WITHIN_SPAN = "not within span";
/// @dev The order count is not > 1.
string constant INVALID_ORDER_COUNT = "invalid order count";
/// @dev The part id is not > 0 and <= n or total number of parts.
string constant PART_NUMBER_OUT_OF_RANGE = "part number out of range";
/// @dev Invalid number of total number of parts, i.e., not greater than 1 and <= type(uint32).max.
string constant INVALID_NUM_PARTS = "invalid num parts";

contract TWAPWithIncreasingMinPartLimit is BaseConditionalOrder {
    // --- types

    struct Data {
        IERC20 sellToken; // The token being sold
        IERC20 buyToken; // The token being bought
        address receiver; // The order owner (user who initiated the order)
        uint256 partSellAmount; // The amount to sell in each part
        uint256 startPrice; // Sell price for the first part
        uint256 endPrice; // Sell price for the last part
        uint256 t0; // Start timestamp
        uint256 t; // Time interval for each part
        uint256 n; // Number of parts
        uint256 part; // Part number or identifier from 1...n
        uint256 span; // Time span of interval t for each part
        bytes32 appData; // Application-specific data
    }

    ComposableCoW public immutable composableCow;

    constructor(ComposableCoW _composableCow) {
        composableCow = _composableCow;
    }

    /// @inheritdoc IConditionalOrderGenerator
    /// @dev `owner`, `sender` and `offchainInput` is not used.
    function getTradeableOrder(address owner, address, bytes32 ctx, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        // Decode the payload into the twap with increasing minPartLimit parameters.
        Data memory data = abi.decode(staticInput, (Data));

        // Get the sell price for the part
        uint256 sellPrice = _getSellPrice(data);

        // Set up the TWAPData for order generation
        TWAPOrder.Data memory twap = TWAPOrder.Data({
            sellToken: data.sellToken,
            buyToken: data.buyToken,
            receiver: data.receiver,
            partSellAmount: data.partSellAmount,
            minPartLimit: sellPrice, // Replace minPartLimit with the computed sellPrice for the specific part
            t0: data.t0,
            n: data.n,
            t: data.t,
            span: data.span,
            appData: data.appData
        });

        // Validate part and generate GPv2Order data for the part
        /// @dev If `twap.t0` is set to 0, then get the start time from the context.
        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }

        order = TWAPOrder.orderFor(twap);

        /// @dev Revert if the order is outside the TWAP bundle's span.
        if (!(block.timestamp <= order.validTo)) {
            revert IConditionalOrder.OrderNotValid(NOT_WITHIN_SPAN);
        }
    }

    /// @dev Calculate the increment factor to increase the price.
    /// i.e., incrementFactor = (endPrice / startPrice) ^ (1 / (n - 1))
    /// @param startPrice The starting price.
    /// @param endPrice The ending price.
    /// @param orderCount The number of orders.
    /// @return incrementFactor The factor by which the price will increase between orders.
    function _getIncrementFactor(uint256 startPrice, uint256 endPrice, uint256 orderCount)
        internal
        pure
        returns (uint256)
    {
        if (!(orderCount > 1)) {
            revert IConditionalOrder.OrderNotValid(INVALID_ORDER_COUNT);
        }

        uint256 fraction = (endPrice * 1e18) / startPrice;
        return _pow(fraction, 1e18 / (orderCount - 1));
    }

    /// @dev Power function to calculate the increment factor.
    /// @param base The base to be raised to the power.
    /// @param exponent The exponent to raise the base to.
    /// @return result The result of raising the base to the exponent.
    function _pow(uint256 base, uint256 exponent) internal pure returns (uint256) {
        uint256 result = 1e18;
        while (exponent > 0) {
            if (exponent % 2 == 1) {
                result = (result * base) / 1e18;
            }
            base = (base * base) / 1e18;
            exponent /= 2;
        }
        return result;
    }

    /// @dev Compute the sell price for a given part index in a TWAP order.
    /// @param data The TWAP order data containing startPrice, endPrice, n (total parts), and current part index.
    /// @return sellPrice The calculated sell price for the given part.
    function _getSellPrice(Data memory data) internal pure returns (uint256 sellPrice) {
        if (!(data.part > 0 && data.part <= data.n)) revert IConditionalOrder.OrderNotValid(PART_NUMBER_OUT_OF_RANGE);
        if (!(data.n > 1 && data.n <= type(uint32).max)) revert IConditionalOrder.OrderNotValid(INVALID_NUM_PARTS);

        // Avoid overflow when exponent is small
        if (data.part == 1) {
            return data.startPrice;
        }

        // Calculate the incremental factor
        uint256 incrementFactor = _getIncrementFactor(data.startPrice, data.endPrice, data.n);

        // Calculate the sell price for the given part using exponential growth formula
        // i.e., incrementFactor^(part-1), multiplied by startPrice
        uint256 exponent = ((data.part - 1) * 1e18) / (data.n - 1);
        sellPrice = (data.startPrice * _pow(incrementFactor, exponent)) / 1e18;
    }
}
