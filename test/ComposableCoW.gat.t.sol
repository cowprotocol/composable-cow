// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271} from "safe/handler/extensible/SignatureVerifierMuxer.sol";

import "./ComposableCoW.base.t.sol";

import "../src/types/GoodAfterTime.sol";

contract ComposableCoWGatTest is BaseComposableCoWTest {
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];
    using SafeLib for Safe;

    GoodAfterTime gat;

    TestExpectedOutCalculator testOutCalculator;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        // deploy the GAT handler
        gat = new GoodAfterTime();

        // deploy the test expected out calculator
        testOutCalculator = new TestExpectedOutCalculator();
    }

    /**
     * @dev Fuzz test revert on invalid start time
     */
    function test_getTradeableOrder_FuzzRevertBeforeStartTime(uint256 currentTime, uint256 startTime) public {
        // Revert when the start time is before the current time
        vm.assume(currentTime < startTime);

        GoodAfterTime.Data memory o = _gatTest(hex"");
        o.startTime = startTime;

        // Warp to the current time
        vm.warp(currentTime);

        // should revert when the current time is before the start time
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, TOO_EARLY));
        gat.getTradeableOrder(address(safe1), address(0), bytes32(0), abi.encode(o), abi.encode(uint256(1e18)));
    }

    /**
     * @dev Fuzz test revert on balance too low
     */
    function test_getTradeableOrder_FuzzRevertBelowMinBalance(uint256 currentBalance, uint256 minBalance) public {
        // Revert when the current balance is below the minimum balance
        vm.assume(currentBalance < minBalance);

        GoodAfterTime.Data memory o = _gatTest(hex"");
        o.minSellBalance = minBalance;

        // Warp to the start time
        vm.warp(o.startTime);

        // set the current balance
        deal(address(o.sellToken), address(safe1), currentBalance);

        // should revert when the current balance is below the minimum balance
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, BALANCE_INSUFFICIENT));
        gat.getTradeableOrder(address(safe1), address(0), bytes32(0), abi.encode(o), abi.encode(uint256(1e18)));
    }

    /**
     * @dev Fuzz test revert when oracle supplied buyAmount is less than the price checker
     */
    function test_getTradeableOrder_FuzzRevertTooLowOutput(
        uint256 buyAmount,
        uint256 expectedOut,
        uint256 allowedSlippage
    ) public {
        vm.assume(expectedOut < type(uint256).max / 10000);
        allowedSlippage = bound(allowedSlippage, 0, 10000);
        vm.assume(buyAmount < expectedOut * (10000 - allowedSlippage) / 10000);

        GoodAfterTime.PriceCheckerPayload memory checker = GoodAfterTime.PriceCheckerPayload({
            checker: testOutCalculator,
            payload: abi.encode(expectedOut),
            allowedSlippage: allowedSlippage
        });

        GoodAfterTime.Data memory o = _gatTest(abi.encode(checker));

        // Warp to the start time
        vm.warp(o.startTime);

        // set the current balance
        deal(address(o.sellToken), address(safe1), o.minSellBalance);

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, PRICE_CHECKER_FAILED));
        gat.getTradeableOrder(address(safe1), address(0), bytes32(0), abi.encode(o), abi.encode(buyAmount));
    }

    function test_getTradeableOrder_FuzzContext(
        IERC20 buyToken,
        address owner,
        address receiver,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 startTime,
        uint256 endTime,
        bool allowPartialFill
    ) public {
        // guard against 32 bit overflow
        vm.assume(endTime < type(uint32).max);
        vm.assume(startTime < endTime);

        GoodAfterTime.Data memory o = GoodAfterTime.Data({
            sellToken: token0,
            buyToken: buyToken,
            receiver: receiver,
            sellAmount: sellAmount,
            minSellBalance: 0,
            startTime: startTime,
            endTime: endTime,
            allowPartialFill: allowPartialFill,
            priceCheckerPayload: hex"",
            appData: keccak256("GoodAfterTime")
        });

        // Warp to the start time
        vm.warp(o.startTime);

        // set the current balance
        deal(address(o.sellToken), address(safe1), o.minSellBalance);

        // This should not revert
        GPv2Order.Data memory order =
            gat.getTradeableOrder(owner, address(0), bytes32(0), abi.encode(o), abi.encode(buyAmount));

        GPv2Order.Data memory comparison = GPv2Order.Data({
            sellToken: token0,
            buyToken: buyToken,
            receiver: receiver,
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: uint32(endTime),
            appData: keccak256("GoodAfterTime"),
            feeAmount: 0, // zero fee for limit order
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: allowPartialFill,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });

        assertEq(
            GPv2Order.hash(order, settlement.domainSeparator()),
            GPv2Order.hash(comparison, settlement.domainSeparator())
        );
    }

    function test_getTradeableOrder_e2e_Fuzz(
        uint256 currentTime,
        uint256 startTime,
        uint256 endTime,
        uint256 minBalance,
        uint256 currentBalance,
        uint256 buyAmount
    ) public {
        // guard against 32 bit overflow
        vm.assume(endTime < type(uint32).max);
        vm.assume(startTime < endTime);
        // Guard against currentTime out of range
        currentTime = bound(currentTime, startTime, endTime);
        // Guard against minBalance out of range
        currentBalance = bound(currentBalance, minBalance, type(uint256).max);

        GoodAfterTime.Data memory o = _gatTest(hex"");
        o.startTime = startTime;
        o.endTime = endTime;
        o.minSellBalance = minBalance;

        // Create the order - this signs the order and marks it a valid
        IConditionalOrder.ConditionalOrderParams memory params = createOrder(safe1, o, o.sellToken, o.sellAmount);

        // Warp to the current time
        vm.warp(currentTime);

        // set the current balance
        deal(address(o.sellToken), address(safe1), currentBalance);

        // This should not revert
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(buyAmount), new bytes32[](0)
        );

        // Verify that the order is valid - this shouldn't revert
        assertTrue(
            ExtensibleFallbackHandler(address(safe1)).isValidSignature(
                GPv2Order.hash(order, settlement.domainSeparator()), signature
            ) == ERC1271.isValidSignature.selector
        );
    }

    function test_getTradeableOrder_e2e_FuzzWithPriceChecker(
        uint256 startTime,
        uint256 endTime,
        uint256 buyAmount,
        uint256 expectedOut,
        uint256 allowedSlippage
    ) public {
        // guard against 32 bit overflow
        vm.assume(endTime < type(uint32).max);
        vm.assume(startTime < endTime);
        // Ensure that the expected out and buy amount are in range
        vm.assume(expectedOut < type(uint256).max / 10000);
        allowedSlippage = bound(allowedSlippage, 0, 10000);
        vm.assume(buyAmount >= expectedOut * (10000 - allowedSlippage) / 10000);

        // Create the price checker payload
        GoodAfterTime.PriceCheckerPayload memory checker = GoodAfterTime.PriceCheckerPayload({
            checker: testOutCalculator,
            payload: abi.encode(expectedOut),
            allowedSlippage: allowedSlippage
        });

        // Create the order payload
        GoodAfterTime.Data memory o = _gatTest(abi.encode(checker));
        o.startTime = startTime;
        o.endTime = endTime;

        // Create the order - this signs the order and marks it a valid
        IConditionalOrder.ConditionalOrderParams memory params = createOrder(safe1, o, o.sellToken, o.sellAmount);

        // Warp to the current time
        vm.warp(startTime);

        // set the current balance
        deal(address(o.sellToken), address(safe1), o.minSellBalance);

        // This should not revert
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(buyAmount), new bytes32[](0)
        );

        // Verify that the order is valid - this shouldn't revert
        assertTrue(
            ExtensibleFallbackHandler(address(safe1)).isValidSignature(
                GPv2Order.hash(order, settlement.domainSeparator()), signature
            ) == ERC1271.isValidSignature.selector
        );
    }

    /**
     * @dev Test that the order is valid when within the time bounds
     */
    function test_verify_e2e_fuzz(
        uint256 startTime,
        uint256 endTime,
        uint256 buyAmount,
        uint256 expectedOut,
        uint256 allowedSlippage
    ) public {
        // guard against 32 bit overflow
        vm.assume(endTime < type(uint32).max);
        vm.assume(startTime < endTime);
        vm.assume(expectedOut < type(uint256).max / 10000);
        allowedSlippage = bound(allowedSlippage, 0, 10000);
        vm.assume(buyAmount >= expectedOut * (10000 - allowedSlippage) / 10000);

        // Create the price checker payload
        GoodAfterTime.PriceCheckerPayload memory checker = GoodAfterTime.PriceCheckerPayload({
            checker: testOutCalculator,
            payload: abi.encode(expectedOut),
            allowedSlippage: allowedSlippage
        });

        // Create the order payload
        GoodAfterTime.Data memory o = _gatTest(abi.encode(checker));
        o.startTime = startTime;

        // Warp to the current time
        vm.warp(startTime);

        // set the current balance
        deal(address(o.sellToken), address(safe1), o.minSellBalance);

        GPv2Order.Data memory order =
            gat.getTradeableOrder(address(safe1), address(0), bytes32(0), abi.encode(o), abi.encode(buyAmount));
        bytes32 domainSeparator = composableCow.domainSeparator();

        // Verify that the order is valid - this shouldn't revert
        gat.verify(
            address(safe1),
            address(0),
            GPv2Order.hash(order, domainSeparator),
            domainSeparator,
            bytes32(0),
            abi.encode(o),
            abi.encode(buyAmount),
            order
        );
    }

    /**
     * @dev Test the entire flow of a GAT order from `ComposableCoW`'s perspective
     */
    function test_settle_e2e() public {
        // Create the price checker payload
        GoodAfterTime.PriceCheckerPayload memory checker =
            GoodAfterTime.PriceCheckerPayload({checker: testOutCalculator, payload: abi.encode(1), allowedSlippage: 50});

        // Create the order payload
        GoodAfterTime.Data memory o = _gatTest(abi.encode(checker));

        // Create the order - this signs the order and marks it a valid
        IConditionalOrder.ConditionalOrderParams memory params = createOrder(safe1, o, o.sellToken, o.sellAmount);

        deal(address(o.sellToken), address(safe1), o.minSellBalance);

        // Warp to the current time
        vm.warp(o.startTime);

        // 4. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(uint256(100)), new bytes32[](0)
        );

        // 5. Execute the order
        settle(address(safe1), bob, order, signature, hex"");
    }

    // --- Helper functions ---

    function createOrder(Safe safe, GoodAfterTime.Data memory gatOrder, IERC20 sellToken, uint256 sellAmount)
        internal
        returns (IConditionalOrder.ConditionalOrderParams memory params)
    {
        params = super.createOrder(gat, keccak256("gat"), abi.encode(gatOrder));

        // create the order
        _create(address(safe), params, false);
        // deal the sell token to the safe
        deal(address(sellToken), address(safe), sellAmount);
        // authorize the vault relayer to pull the sell token from the safe
        vm.prank(address(safe));
        sellToken.approve(address(relayer), sellAmount);
    }

    function _gatTest(bytes memory priceCheckerPayload) internal view returns (GoodAfterTime.Data memory) {
        return GoodAfterTime.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            minSellBalance: 200e18,
            startTime: block.timestamp + 1 days,
            endTime: block.timestamp + 2 days,
            allowPartialFill: false,
            priceCheckerPayload: priceCheckerPayload,
            appData: keccak256("GoodAfterTime")
        });
    }
}

/// @dev A test implementation that returns what we tell it to..
contract TestExpectedOutCalculator is IExpectedOutCalculator {
    function getExpectedOut(uint256, IERC20, IERC20, bytes memory _data) external pure override returns (uint256) {
        return abi.decode(_data, (uint256));
    }
}
