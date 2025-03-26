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

import {wadPow} from "../vendored/SignedWadMath.sol";

// --- error strings

/// @dev The part id is not > 0 and <= n or total number of parts.
string constant PART_NUMBER_OUT_OF_RANGE = "part number out of range";
/// @dev The sell token and buy token are the same.
string constant INVALID_SAME_TOKEN = "same token";
/// @dev The sell token and buy token addresses should both not be address(0).
string constant INVALID_TOKEN = "invalid token";
/// @dev The part sell amount is not greater than zero.
string constant INVALID_PART_SELL_AMOUNT = "invalid part sell amount";
/// @dev The minimum buy amount in each part (limit) is not gretater than zero.
string constant INVALID_MIN_PART_LIMIT = "invalid min part limit";
/// @dev The valid until time is invalid.
string constant INVALID_VALID_TO_TIME = "invalid valid until time";
/// @dev The percentage increase is zero.
string constant INVALID_PERCENTAGE_INCREASE = "invalid percentage increase";

/// @title BatchLimitSell Conditional Order
/// @notice A custom order type for the CoW Protocol Conditional Order Framework.
/// @dev This order allows placing a batch limit sell order, where each part in the batch 
///      is sold at a price incremented by a fixed percentage relative to the previous part.
contract BatchLimitSell is BaseConditionalOrder {
    // --- types

    struct Data {
        IERC20 sellToken; // The token being sold
        IERC20 buyToken; // The token being bought
        address receiver; // The order owner (user who initiated the order)
        uint256 partSellAmount; // The amount to sell in each part
        uint256 startPrice; // Sell price for the first part
        uint256 percentageIncrease; // Percentage increase for each part in wad
        uint256 validTo; // when the order expires
        uint256 n; // Number of parts
        uint256 part; // Part number or identifier from 1...n
        bytes32 appData; // Application-specific data
    }

    ComposableCoW public immutable COMPOSABLE_COW;

    constructor(ComposableCoW _composableCow) {
        COMPOSABLE_COW = _composableCow;
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

        /**
         * @dev If `data.validTo` is set to 0, then get the validTo time from the context.
         */
        if (data.validTo == 0) {
            data.validTo = uint256(COMPOSABLE_COW.cabinet(owner, ctx));
        }

        _validate(data); 

        // Get the min part limit for the part
        uint256 minPartLimit = _getMinPartLimit(data);

        if (!(minPartLimit > 0)) revert IConditionalOrder.OrderNotValid(INVALID_MIN_PART_LIMIT);
        
        order = GPv2Order.Data({
            sellToken: data.sellToken,
            buyToken: data.buyToken,
            receiver: data.receiver,
            sellAmount: data.partSellAmount,
            buyAmount: minPartLimit,
            validTo: uint32(data.validTo),
            appData: data.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
    
    /// @dev revert if the order is invalid
    /// @param data The TWAP order to validate
    function _validate(Data memory data) internal view {
        if (!(data.n > 1 && data.n <= type(uint32).max && data.part > 0 && data.part <= data.n)) {
            revert IConditionalOrder.OrderNotValid(PART_NUMBER_OUT_OF_RANGE);
        }
        if (!(data.sellToken != data.buyToken)) revert IConditionalOrder.OrderNotValid(INVALID_SAME_TOKEN);
        if (!(address(data.sellToken) != address(0) && address(data.buyToken) != address(0))) {
            revert IConditionalOrder.OrderNotValid(INVALID_TOKEN);
        }
        if (!(data.partSellAmount > 0)) revert IConditionalOrder.OrderNotValid(INVALID_PART_SELL_AMOUNT);
        if (!(data.validTo > block.timestamp && data.validTo <= 365 days)) revert IConditionalOrder.OrderNotValid(INVALID_VALID_TO_TIME);
        if (!(data.percentageIncrease > 0)) revert IConditionalOrder.OrderNotValid(INVALID_PERCENTAGE_INCREASE);
    }

    /// @dev Power function to calculate the increment factor.
    /// @param base The base to be raised to the power.
    /// @param exponent The exponent to raise the base to.
    /// @return result The result of raising the base to the exponent.
    function _pow(uint256 base, uint256 exponent) internal pure returns (uint256) {
        return uint256(wadPow(int256(base), int256(exponent)));
    }

    /// @dev Compute the minimum buy amount in each part (limit).
    /// @param data The TWAP order data containing startPrice, endPrice, n (total parts), and current part index.
    /// @return minPartLimit The calculated minimum buy amount in each part (limit).
    function _getMinPartLimit(Data memory data) internal pure returns (uint256 minPartLimit) {
        if (data.part == 1) {
            return data.startPrice;
        }
        uint256 incrementFactor = 1e18 + (data.percentageIncrease * 1e16);
        uint256 exponent = (data.part - 1) * 1e18 / (data.n - 1);
        minPartLimit = (data.startPrice * _pow(incrementFactor, exponent)) / 1e18;
    }
}
