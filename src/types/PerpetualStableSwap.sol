// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order, IConditionalOrder, BaseConditionalOrder} from "../BaseConditionalOrder.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

/// @title PerpetualStableSwap - 1:1 swaps between token pairs with spread
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Always willing to trade between tokenA and tokenB at 1:1 (adjusted for decimals) plus spread.
contract PerpetualStableSwap is BaseConditionalOrder {
    struct Data {
        IERC20 tokenA;
        IERC20 tokenB;
        uint32 validityBucketSeconds;
        uint256 halfSpreadBps;
        bytes32 appData;
    }

    struct BuySellData {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        Data memory data = abi.decode(staticInput, (Data));

        BuySellData memory buySellData = side(owner, data);

        require(buySellData.sellAmount > 0, IConditionalOrder.OrderNotValid("not funded"));

        order = GPv2Order.Data(
            buySellData.sellToken,
            buySellData.buyToken,
            address(0),
            buySellData.sellAmount,
            buySellData.buyAmount,
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

    function side(address owner, Data memory data) internal view returns (BuySellData memory buySellData) {
        IERC20 tokenA = IERC20(address(data.tokenA));
        IERC20 tokenB = IERC20(address(data.tokenB));
        uint256 balanceA = tokenA.balanceOf(owner);
        uint256 balanceB = tokenB.balanceOf(owner);

        if (convertAmount(tokenA, balanceA, tokenB) > balanceB) {
            buySellData = BuySellData({
                sellToken: tokenA,
                buyToken: tokenB,
                sellAmount: balanceA,
                buyAmount: convertAmount(tokenA, balanceA, tokenB) * (Utils.MAX_BPS + data.halfSpreadBps)
                    / Utils.MAX_BPS
            });
        } else {
            buySellData = BuySellData({
                sellToken: tokenB,
                buyToken: tokenA,
                sellAmount: balanceB,
                buyAmount: convertAmount(tokenB, balanceB, tokenA) * (Utils.MAX_BPS + data.halfSpreadBps)
                    / Utils.MAX_BPS
            });
        }
    }

    function convertAmount(IERC20 srcToken, uint256 srcAmount, IERC20 destToken)
        internal
        view
        returns (uint256 destAmount)
    {
        uint8 srcDecimals = srcToken.decimals();
        uint8 destDecimals = destToken.decimals();

        if (srcDecimals > destDecimals) {
            destAmount = srcAmount / (10 ** (srcDecimals - destDecimals));
        } else {
            destAmount = srcAmount * (10 ** (destDecimals - srcDecimals));
        }
    }
}
