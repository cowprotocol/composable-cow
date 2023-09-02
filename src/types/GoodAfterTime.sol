// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../vendored/Milkman.sol";
import "../BaseConditionalOrder.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

// --- error strings
/// @dev If the trade is called before the time it becomes valid.
string constant TOO_EARLY = "too early";
/// @dev If the sell token balance is below the minimum.
string constant BALANCE_INSUFFICIENT = "balance insufficient";
/// @dev If the price checker fails.
string constant PRICE_CHECKER_FAILED = "price checker failed";

/**
 * @title Good After Time (GAT) Conditional Order - with Milkman price checkers
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Designed to be used with the CoW Protocol Conditional Order Framework.
 *      This order type allows for placing an order that is valid after a certain time
 *      and that has an optional minimum `sellAmount` determined by a price checker. The
 *      actual `buyAmount` is determined by off chain input. As changing the `buyAmount`
 *      changes the `orderUid` of the order, this allows for placing multiple orders. To
 *      ensure that the order is not filled multiple times, a `minSellBalance` is
 *      checked before the order is placed.
 */
contract GoodAfterTime is BaseConditionalOrder {
    using SafeCast for uint256;

    // --- types

    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 sellAmount; // buy amount comes from offchainInput
        uint256 minSellBalance;
        uint256 startTime; // when the order becomes valid
        uint256 endTime; // when the order expires
        bool allowPartialFill;
        bytes priceCheckerPayload;
        bytes32 appData;
    }

    struct PriceCheckerPayload {
        IExpectedOutCalculator checker;
        bytes payload;
        uint256 allowedSlippage; // in basis points
    }

    function getTradeableOrder(
        address owner,
        address,
        bytes32,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) public view override returns (GPv2Order.Data memory order) {
        // Decode the payload into the good after time parameters.
        Data memory data = abi.decode(staticInput, (Data));

        // Don't allow the order to be placed before it becomes valid.
        if (!(block.timestamp >= data.startTime)) {
            revert IConditionalOrder.OrderNotValid(TOO_EARLY);
        }

        // Require that the sell token balance is above the minimum.
        if (!(data.sellToken.balanceOf(owner) >= data.minSellBalance)) {
            revert IConditionalOrder.OrderNotValid(BALANCE_INSUFFICIENT);
        }

        uint256 buyAmount = abi.decode(offchainInput, (uint256));

        // Optionally check the price checker.
        if (data.priceCheckerPayload.length > 0) {
            // Decode the payload into the price checker parameters.
            PriceCheckerPayload memory p = abi.decode(data.priceCheckerPayload, (PriceCheckerPayload));

            // Get the expected out from the price checker.
            uint256 _expectedOut = p.checker.getExpectedOut(data.sellAmount, data.sellToken, data.buyToken, p.payload);

            // Don't allow the order to be placed if the buyAmount is less than the minimum out.
            if (!(buyAmount >= (_expectedOut * (Utils.MAX_BPS - p.allowedSlippage)) / Utils.MAX_BPS)) {
                revert IConditionalOrder.OrderNotValid(PRICE_CHECKER_FAILED);
            }
        }

        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            data.sellAmount,
            buyAmount,
            data.endTime.toUint32(),
            data.appData,
            0, // use zero fee for limit orders
            GPv2Order.KIND_SELL,
            data.allowPartialFill,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}
