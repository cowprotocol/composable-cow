// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271} from "safe/handler/extensible/SignatureVerifierMuxer.sol";

import "./ComposableCoW.base.t.sol";

import "../src/interfaces/IWatchtowerCustomErrors.sol";
import "../src/types/TradeAboveThreshold.sol";
import {ConditionalOrdersUtilsLib as Utils} from "../src/types/ConditionalOrdersUtilsLib.sol";

contract ComposableCoWTatTest is BaseComposableCoWTest {
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];
    using SafeLib for Safe;

    TradeAboveThreshold tat;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        // deploy the TAT handler
        tat = new TradeAboveThreshold();
    }

    /**
     * @dev Fuzz test revert on balance too low
     */
    function test_getTradeableOrder_FuzzRevertBelowThreshold(uint256 currentBalance, uint256 threshold) public {
        // Revert when the current balance is below the minimum balance
        vm.assume(currentBalance < threshold);

        TradeAboveThreshold.Data memory o = _tatTest();
        o.threshold = threshold;

        uint256 currentBlock = 1337;
        vm.roll(currentBlock);

        // set the current balance
        deal(address(o.sellToken), address(safe1), currentBalance);

        // should revert when the current balance is below the minimum balance
        vm.expectRevert(
            abi.encodeWithSelector(
                IWatchtowerCustomErrors.PollTryAtBlock.selector,
                currentBlock + 1,
                BALANCE_INSUFFICIENT
            )
        );
        tat.getTradeableOrder(address(safe1), address(0), bytes32(0), abi.encode(o), bytes(""));
    }

    function test_BalanceMet_fuzz(
        address receiver,
        uint256 threshold,
        bytes32 appData,
        uint256 currentBalance
    ) public {
        vm.assume(threshold > 0);
        vm.assume(currentBalance >= threshold);

        // Use same time data from stop loss test
        vm.warp(1687718451);

        TradeAboveThreshold.Data memory data = TradeAboveThreshold.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: receiver,
            validityBucketSeconds: 15 minutes,
            threshold: threshold,
            appData: appData
        });


        // // set the current balance
        deal(address(token0), address(safe1), currentBalance);

        // This should not revert
        GPv2Order.Data memory order =
            tat.getTradeableOrder(address(safe1), address(0), bytes32(0), abi.encode(data), bytes(""));


        assertEq(address(order.sellToken), address(token0));
        assertEq(address(order.buyToken), address(token1));
        assertEq(order.sellAmount, currentBalance);
        assertEq(order.buyAmount, 1);
        assertEq(order.receiver, receiver);
        assertEq(order.validTo, 1687718700);
        assertEq(order.appData, appData);
        assertEq(order.feeAmount, 0);
        assertEq(order.kind, GPv2Order.KIND_SELL);
        assertEq(order.partiallyFillable, false);
        assertEq(order.sellTokenBalance, GPv2Order.BALANCE_ERC20);
        assertEq(order.buyTokenBalance, GPv2Order.BALANCE_ERC20);
    }

    // --- Helper functions ---

    function _tatTest() internal view returns (TradeAboveThreshold.Data memory) {
        return TradeAboveThreshold.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            validityBucketSeconds: 15 minutes,
            threshold: 200e18,
            appData: keccak256("TradeAboveThreshold")
        });
    }
}
