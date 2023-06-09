// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "@openzeppelin/interfaces/IERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";

import "../vendored/Milkman.sol";
import "../BaseConditionalOrder.sol";

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

    uint256 private constant MAX_BPS = 10000;

    // --- types
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount; // buy amount comes from offchainInput
        uint256 minSellBalance;
        uint256 startTime; // when the order becomes valid
        uint256 endTime; // when the order expires
        bool allowPartialFill;
        bytes priceCheckerPayload;
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
            revert IConditionalOrder.OrderNotValid();
        }

        // Require that the sell token balance is above the minimum.
        if (!(data.sellToken.balanceOf(owner) >= data.minSellBalance)) {
            revert IConditionalOrder.OrderNotValid();
        }

        uint256 buyAmount = abi.decode(offchainInput, (uint256));

        // Optionally check the price checker.
        if (data.priceCheckerPayload.length > 0) {
            // Decode the payload into the price checker parameters.
            PriceCheckerPayload memory p = abi.decode(data.priceCheckerPayload, (PriceCheckerPayload));

            // Get the expected out from the price checker.
            uint256 _expectedOut = p.checker.getExpectedOut(data.sellAmount, data.sellToken, data.buyToken, p.payload);

            // Don't allow the order to be placed if the sellAmount is less than the minimum out.
            if (!(buyAmount >= (_expectedOut * (MAX_BPS - p.allowedSlippage)) / MAX_BPS)) {
                revert IConditionalOrder.OrderNotValid();
            }
        }

        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            address(0),
            data.sellAmount,
            buyAmount,
            data.endTime.toUint32(),
            keccak256("GoodAfterTime"),
            0, // use zero fee for limit orders
            GPv2Order.KIND_SELL,
            data.allowPartialFill,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}
