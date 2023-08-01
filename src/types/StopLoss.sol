// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "@openzeppelin/interfaces/IERC20.sol";

import "../BaseConditionalOrder.sol";
import "../interfaces/IAggregatorV3Interface.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

/**
 * @title StopLoss conditional order
 * Requires providing two price oracles (e.g. chainlink) and a strike price. If the sellToken price falls below the strike price, the order will be triggered
 * @notice Both oracles need to be denominated in the same quote currency (e.g. GNO/ETH and USD/ETH for GNO/USD stop loss orders)
 * @dev This order type does not have any replay protection, meaning it may trigger again in the next validityBucket (e.g. 00:15-00:30)
 */
contract StopLoss is BaseConditionalOrder {

    /**
     * Defines the parameters of a StopLoss order
     * @param sellToken: the token to be sold
     * @param buyToken: the token to be bought
     * @param sellTokenPriceOracle: A chainlink-like oracle returning the current sell token price in a given numeraire
     * @param buyTokenPriceOracle: A chainlink-like oracle returning the current buy token price in the same numeraire
     * @param strike: The exchange rate (denominated in sellToken/buyToken) which triggers the StopLoss order if the oracle price falls below
     * @param sellAmount: In case of a sell order, the exact amount of tokens the order is willing to sell. In case of a buy order, the maximium amount of tokens it is willing to sell
     * @param buyAmount: In case of a sell order, the min amount of tokens the order is wants to receive. In case of a buy order, the exact amount of tokens it is willing to receive
     * @param appData: The IPFS hash of the appData associated with the order
     * @param receiver: The account that should receive the proceeds of the trade
     * @param isSellOrder: Whether this is a sell or buy order
     * @param isPartiallyFillable: Whether solvers are allowed to only fill a fraction of the order (useful if exact sell or buy amount isn't know at time of placement)
     * @param validityBucketSeconds: How long the order will be valid. E.g. if the validityBucket is set to 15 minutes and the order is placed at 00:08, it will be valid until 00:15
     */
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        IAggregatorV3Interface sellTokenPriceOracle;
        IAggregatorV3Interface buyTokenPriceOracle;
        int256 strike;
        uint256 sellAmount;
        uint256 buyAmount;
        bytes32 appData;
        address receiver;
        bool isSellOrder;
        bool isPartiallyFillable;
        uint32 validityBucketSeconds;
    }

    function getTradeableOrder(
        address,
        address,
        bytes32,
        bytes calldata staticInput,
        bytes calldata
    ) public view override returns (GPv2Order.Data memory order) {
        Data memory data = abi.decode(staticInput, (Data));
        (, int256 latestSellPrice, , , ) = data.sellTokenPriceOracle.latestRoundData();
        (, int256 latestBuyPrice, , , ) = data.buyTokenPriceOracle.latestRoundData();

        if (!(latestSellPrice/latestBuyPrice <= data.strike)) {
            revert IConditionalOrder.OrderNotValid();
        }

        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            data.sellAmount,
            data.buyAmount,
            Utils.validToBucket(data.validityBucketSeconds),
            data.appData,
            0, // use zero fee for limit orders
            data.isSellOrder ? GPv2Order.KIND_SELL : GPv2Order.KIND_BUY,
            data.isPartiallyFillable, 
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}
