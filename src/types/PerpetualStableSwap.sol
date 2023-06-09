// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {SafeMath} from "@openzeppelin/utils/math/SafeMath.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/interfaces/IERC20Metadata.sol";

import "../BaseConditionalOrder.sol";

// @title A smart contract that is always willing to trade between tokenA and tokenB 1:1,
// taking decimals into account (and adding specifiable spread)
contract PerpetualStableSwap is BaseConditionalOrder {
    using GPv2Order for GPv2Order.Data;
    using SafeMath for uint256;
    using SafeMath for uint8;

    // /**
    //  * Creates a new perpetual swap order. All resulting swaps will be made from the target contract.
    //  * @param _tokenA One of the two tokens that can be perpetually swapped against one another
    //  * @param _tokenB The other of the two tokens that can be perpetually swapped against one another
    //  * @param _halfSpreadBps The markup to parity (ie 1:1 exchange rate) that is charged for each swap
    //  */

    struct Data {
        IERC20 tokenA;
        IERC20 tokenB;
        uint32 validity;
        uint256 halfSpreadBps;
    }

    struct BuySellData {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
    }

    // There are 10k basis points in a unit
    uint256 private constant BPS = 10_000;

    /**
     * @inheritdoc IConditionalOrderGenerator
     */
    function getTradeableOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        /// @dev Decode the payload into the perpetual stable swap parameters.
        PerpetualStableSwap.Data memory data = abi.decode(staticInput, (Data));

        // Always sell whatever of the two tokens we have more of
        BuySellData memory buySellData = side(owner, data);
        // (IERC20 sellToken, IERC20 buyToken, uint256 sellAmount, uint256 buyAmount) = side(owner, data);
        require(buySellData.sellAmount > 0, "not funded");

        // Unless spread is 0 (and there is no surplus), order collision is not an issue as sell and buy amounts should
        // increase for each subsequent order. We therefore set validity to a large time span
        // Note, that reducing current block to a common start time is needed so that the order returned here
        // does not change between the time it is queried and the time it is settled. Validity will be between 1 & 2 weeks.
        // uint32 validity = 1 weeks;
        // solhint-disable-next-line not-rely-on-time
        uint32 currentTimeBucket = ((uint32(block.timestamp) / data.validity) + 1) * data.validity;
        order = GPv2Order.Data(
            buySellData.sellToken,
            buySellData.buyToken,
            owner,
            buySellData.sellAmount,
            buySellData.buyAmount,
            currentTimeBucket + data.validity,
            keccak256("PerpetualStableSwap"),
            0,
            GPv2Order.KIND_SELL,
            false,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }

    function side(address owner, PerpetualStableSwap.Data memory data)
        internal
        view
        returns (BuySellData memory buySellData)
    {
        IERC20Metadata tokenA = IERC20Metadata(address(data.tokenA));
        IERC20Metadata tokenB = IERC20Metadata(address(data.tokenB));
        uint256 balanceA = tokenA.balanceOf(owner);
        uint256 balanceB = tokenB.balanceOf(owner);

        if (convertAmount(tokenA, balanceA, tokenB) > balanceB) {
            buySellData = BuySellData({
                sellToken: tokenA,
                buyToken: tokenB,
                sellAmount: balanceA,
                buyAmount: convertAmount(tokenA, balanceA, tokenB).mul(BPS.add(data.halfSpreadBps)).div(BPS)
            });
        } else {
            buySellData = BuySellData({
                sellToken: tokenB,
                buyToken: tokenA,
                sellAmount: balanceB,
                buyAmount: convertAmount(tokenB, balanceB, tokenA).mul(BPS.add(data.halfSpreadBps)).div(BPS)
            });
        }
    }

    function convertAmount(IERC20Metadata srcToken, uint256 srcAmount, IERC20Metadata destToken)
        internal
        view
        returns (uint256 destAmount)
    {
        uint8 srcDecimals = srcToken.decimals();
        uint8 destDecimals = destToken.decimals();

        if (srcDecimals > destDecimals) {
            destAmount = srcAmount.div(10 ** (srcDecimals.sub(destDecimals)));
        } else {
            destAmount = srcAmount.mul(10 ** (destDecimals.sub(srcDecimals)));
        }
    }
}
