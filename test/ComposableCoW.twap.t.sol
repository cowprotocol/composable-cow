// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC1271} from "safe/handler/extensible/SignatureVerifierMuxer.sol";

import "./ComposableCoW.base.t.sol";

import "../src/types/twap/TWAP.sol";
import "../src/types/twap/libraries/TWAPOrder.sol";
import "../src/types/twap/libraries/TWAPOrderMathLib.sol";

import "../src/value_factories/CurrentBlockTimestampFactory.sol";

uint256 constant SELL_AMOUNT = 24000e18;
uint256 constant LIMIT_PRICE = 100e18;
uint32 constant FREQUENCY = 1 hours;
uint32 constant NUM_PARTS = 24;
uint32 constant SPAN = 5 minutes;

contract ComposableCoWTwapTest is BaseComposableCoWTest {
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];
    using SafeLib for Safe;

    TWAPOrder.Data defaultBundle;
    bytes32 defaultBundleHash;
    bytes defaultBundleBytes;
    IValueFactory currentBlockTimestampFactory;

    mapping(bytes32 => uint256) public orderFills;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        // deploy the TWAP handler
        twap = new TWAP(composableCow);

        // deploy the current block timestamp factory
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();

        // Set a default bundle
        defaultBundle = _twapTestBundle(block.timestamp + 1 days);

        deal(address(token0), address(safe1), SELL_AMOUNT);

        createOrder(safe1, defaultBundle, defaultBundle.sellToken, defaultBundle.partSellAmount * defaultBundle.n);
    }

    /**
     * @dev Revert when the sell token and buy token are the same
     */
    function test_validateData_RevertOnSameTokens() public {
        // Revert when the same token is used for both the buy and sell token
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.sellToken = token0;
        o.buyToken = token0;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_SAME_TOKEN));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Revert when either the buy or sell token is address(0)
     */
    function test_validateData_RevertOnTokenZero() public {
        // Revert when either the buy or sell token is address(0)
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.sellToken = IERC20(address(0));

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_TOKEN));
        twap.validateData(abi.encode(o));

        o.sellToken = token0;
        o.buyToken = IERC20(address(0));

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_TOKEN));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Revert when the sell amount is 0
     */
    function test_validateData_RevertOnZeroPartSellAmount() public {
        // Revert when the sell amount is zero
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.partSellAmount = 0;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_PART_SELL_AMOUNT));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Revert when the min part limit is 0
     */
    function test_validateData_RevertOnZeroMinPartLimit() public {
        // Revert when the limit is zero
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.minPartLimit = 0;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_MIN_PART_LIMIT));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Concrete revert test on Span if the last part.
     */
    function test_getTradeableOrder_RevertOnOutsideOfSpanLastPart() public {
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);

        vm.warp(block.timestamp + (FREQUENCY * (NUM_PARTS - 1)) + SPAN);
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollNever.selector, NOT_WITHIN_SPAN));
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");
    }

    /**
     * @dev Concrete revert test on Span if not the last part.
     */
    function test_getTradeableOrder_RevertOnOutsideOfSpanNotLastPart() public {
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);

        vm.warp(block.timestamp + (FREQUENCY * (NUM_PARTS - 2)) + SPAN);
        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalOrder.PollTryAtEpoch.selector, o.t0 + (FREQUENCY * (NUM_PARTS - 1)), NOT_WITHIN_SPAN
            )
        );
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");
    }

    /**
     * @dev Fuzz test revert on invalid start time
     */
    function test_validateData_FuzzRevertOnInvalidStartTime(uint256 startTime) public {
        vm.assume(startTime >= type(uint32).max);
        // Revert when the start time exceeds or equals the max uint32
        TWAPOrder.Data memory o = _twapTestBundle(startTime);
        o.t0 = startTime;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_START_TIME));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Fuzz test revert on invalid numParts
     */
    function test_validateData_FuzzRevertOnInvalidNumParts(uint256 numParts) public {
        vm.assume(numParts < 2 || numParts > type(uint32).max);
        // Revert if not an actual TWAP (ie. numParts < 2)
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.n = numParts;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_NUM_PARTS));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Fuzz test revert on invalid frequency
     */
    function test_validateData_FuzzRevertOnInvalidFrequency(uint256 frequency) public {
        vm.assume(frequency < 1 || frequency > 365 days);
        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.t = frequency;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_FREQUENCY));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Fuzz test revert on invalid span
     */
    function test_validateData_FuzzRevertOnInvalidSpan(uint256 frequency, uint256 span) public {
        vm.assume(frequency > 0 && frequency <= 365 days);
        vm.assume(span > frequency);

        TWAPOrder.Data memory o = _twapTestBundle(block.timestamp);
        o.t = frequency;
        o.span = span;

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_SPAN));
        twap.validateData(abi.encode(o));
    }

    /**
     * @dev Fuzz test to make sure that the order reverts if the current time is before the start time
     */
    function test_getTradeableOrder_FuzzRevertIfBeforeStart(uint256 startTime, uint256 currentTime) public {
        // guard against overflows
        vm.assume(startTime < (type(uint32).max - FREQUENCY));
        // force revert before start
        vm.assume(currentTime < startTime);

        // Revert when the order is signed by the safe and cancelled
        TWAPOrder.Data memory o = _twapTestBundle(startTime);

        // Warp to start time to make sure the order is valid
        vm.warp(startTime);

        // Verify that the order is valid - this shouldn't revert
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");

        // Warp to current time
        vm.warp(currentTime);

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollTryAtEpoch.selector, startTime, BEFORE_TWAP_START));
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");
    }

    /**
     * @dev Fuzz test that the order reverts if the current time is after the expiry
     */
    function test_getTradeableOrder_FuzzRevertIfExpired(uint256 startTime, uint256 currentTime) public {
        // guard against overflows
        vm.assume(startTime <= type(uint32).max);
        vm.assume(currentTime <= type(uint32).max);
        // force revert after expiry
        vm.assume(currentTime >= startTime + (FREQUENCY * NUM_PARTS));

        // Revert when the order is signed by the safe and cancelled
        TWAPOrder.Data memory o = _twapTestBundle(startTime);

        // Warp to start time to make sure the order is valid
        vm.warp(startTime);

        // Verify that the order is valid - this shouldn't revert
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");

        // Warp to expiry
        vm.warp(currentTime);

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollNever.selector, AFTER_TWAP_FINISH));
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");
    }

    /**
     * @dev Fuzz test that the order reverts if the current time is outside of the span
     */
    function test_getTradeableOrder_FuzzRevertIfOutsideSpan(uint256 startTime, uint256 currentTime) public {
        // guard against overflows
        vm.assume(startTime < type(uint32).max);
        vm.assume(currentTime < type(uint32).max);
        // guard against revert before start
        vm.assume(startTime < currentTime);
        // guard against revert after expiry
        vm.assume(currentTime < startTime + (FREQUENCY * NUM_PARTS));
        // guard against no reversion when within span
        vm.assume((currentTime - startTime) % FREQUENCY >= SPAN);
        // Revert when the order is signed by the safe and cancelled
        TWAPOrder.Data memory o = _twapTestBundle(startTime);

        vm.warp(startTime);

        // Verify that the order is valid - this shouldn't revert
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");

        // Warp to outside of the span
        vm.warp(currentTime);

        // Just check that it reverts, don't reproduce the whole logic for PollNever / PollAtEpoch
        // do that in a concrete tests.
        vm.expectRevert();
        twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");
    }

    function test_getTradeableOrder_FuzzRevertIfOrderBeforeBlockTimestamp(
        uint256 ctxBlockTimestamp,
        uint256 currentTime
    ) public {
        // guard against overflows
        vm.assume(ctxBlockTimestamp < type(uint32).max);
        vm.assume(currentTime < type(uint32).max);
        // ram the current time to be before the block timestamp
        vm.assume(currentTime < ctxBlockTimestamp);
        TWAPOrder.Data memory o = _twapTestBundle(0);

        // Warp to the ctxBlockTimestamp
        vm.warp(ctxBlockTimestamp);

        // Create the order - this signs the order and marks it as valid
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrderWithContext(safe1, o, o.sellToken, o.partSellAmount * o.n, currentBlockTimestampFactory, hex"");

        assertEq(composableCow.cabinet(address(safe1), composableCow.hash(params)), bytes32(uint256(ctxBlockTimestamp)));

        // Warp to the current time
        vm.warp(currentTime);

        // The below should revert
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalOrder.PollTryAtEpoch.selector, ctxBlockTimestamp, BEFORE_TWAP_START)
        );
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", new bytes32[](0));
    }

    function test_getTradeableOrder_FuzzRevertIfOrderAfterBlocktimestampValidity(
        uint256 ctxBlockTimestamp,
        uint256 currentTime
    ) public {
        // guard against overflows
        vm.assume(ctxBlockTimestamp < type(uint32).max);
        vm.assume(currentTime < type(uint32).max);
        // ram the current time to be after the blocktimestamp + numParts * frequency
        vm.assume(currentTime > ctxBlockTimestamp + (FREQUENCY * NUM_PARTS));
        TWAPOrder.Data memory o = _twapTestBundle(0);

        // Warp to the ctxBlockTimestamp
        vm.warp(ctxBlockTimestamp);

        // Create the order - this signs the order and marks it as valid
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrderWithContext(safe1, o, o.sellToken, o.partSellAmount * o.n, currentBlockTimestampFactory, hex"");

        assertEq(composableCow.cabinet(address(safe1), composableCow.hash(params)), bytes32(uint256(ctxBlockTimestamp)));

        // Warp to the current time
        vm.warp(currentTime);

        // The below should revert
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollNever.selector, AFTER_TWAP_FINISH));
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", new bytes32[](0));
    }

    function test_getTradeableOrder_e2e_fuzz_WithContext(uint32 _blockTimestamp, uint256 currentTime) public {
        // guard against overflows
        vm.assume(_blockTimestamp < type(uint32).max);
        vm.assume(currentTime < type(uint32).max);
        // guard against revert before start
        vm.assume(_blockTimestamp < currentTime);
        // guard against revert after expiry
        vm.assume(currentTime < _blockTimestamp + (FREQUENCY * NUM_PARTS));
        // guard against reversion outside of the span
        vm.assume((currentTime - _blockTimestamp) % FREQUENCY < SPAN);

        TWAPOrder.Data memory o = _twapTestBundle(0);

        // Warp to the _blocktime
        vm.warp(_blockTimestamp);

        // Create the order - this signs the order and marks it a valid
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrderWithContext(safe1, o, o.sellToken, o.partSellAmount * o.n, currentBlockTimestampFactory, hex"");

        assertEq(composableCow.cabinet(address(safe1), composableCow.hash(params)), bytes32(uint256(_blockTimestamp)));

        // This should not revert
        (GPv2Order.Data memory part, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", new bytes32[](0));

        // Verify that the order is valid - this shouldn't revert
        assertTrue(
            ExtensibleFallbackHandler(address(safe1)).isValidSignature(
                GPv2Order.hash(part, settlement.domainSeparator()), signature
            ) == ERC1271.isValidSignature.selector
        );

        // Now remove the order
        vm.prank(address(safe1));
        bytes32 paramsHash = keccak256(abi.encode(params));
        composableCow.remove(paramsHash);
        assertEq(composableCow.cabinet(address(safe1), paramsHash), bytes32(0));
    }

    /**
     * @dev Fuzz test an order that is valid and should not revert from e2e
     */
    function test_getTradeableOrder_e2e_fuzz(uint256 startTime, uint256 currentTime) public {
        // guard against overflows
        vm.assume(startTime < type(uint32).max);
        vm.assume(currentTime < type(uint32).max);
        // guard against revert before start
        vm.assume(startTime < currentTime);
        // guard against revert after expiry
        vm.assume(currentTime < startTime + (FREQUENCY * NUM_PARTS));
        // guard against reversion outside of the span
        vm.assume((currentTime - startTime) % FREQUENCY < SPAN);
        // Revert when the order is signed by the safe and cancelled
        TWAPOrder.Data memory o = _twapTestBundle(startTime);

        // Create the order - this signs the order and marks it a valid
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrder(safe1, o, o.sellToken, o.partSellAmount * o.n);

        // Warp to the current time
        vm.warp(currentTime);

        // This should not revert
        (GPv2Order.Data memory part, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", new bytes32[](0));

        // Verify that the order is valid - this shouldn't revert
        assertTrue(
            ExtensibleFallbackHandler(address(safe1)).isValidSignature(
                GPv2Order.hash(part, settlement.domainSeparator()), signature
            ) == ERC1271.isValidSignature.selector
        );
    }

    /**
     * @dev Test that the order is valid when the current time is within range
     */
    function test_verify_e2e_fuzz(uint256 startTime, uint256 currentTime) public {
        // guard against overflows
        vm.assume(startTime < type(uint32).max);
        vm.assume(currentTime < type(uint32).max);
        // guard against revert before start
        vm.assume(startTime < currentTime);
        // guard against revert after expiry
        vm.assume(currentTime < startTime + (FREQUENCY * NUM_PARTS));
        // guard against reversion outside of the span
        vm.assume((currentTime - startTime) % FREQUENCY < SPAN);
        // Revert when the order is signed by the safe and cancelled
        TWAPOrder.Data memory o = _twapTestBundle(startTime);

        // Warp to the current time
        vm.warp(currentTime);

        GPv2Order.Data memory order = twap.getTradeableOrder(address(0), address(0), bytes32(0), abi.encode(o), hex"");
        bytes32 domainSeparator = composableCow.domainSeparator();

        // Verify that the order is valid - this shouldn't revert
        twap.verify(
            address(0),
            address(0),
            GPv2Order.hash(order, domainSeparator),
            domainSeparator,
            bytes32(0),
            abi.encode(o),
            hex"",
            order
        );
    }

    /**
     * @dev Test the entire flow of a TWAP order from `ComposableCoW`'s perspective
     */
    function test_settle_e2e() public {
        // 1. Get the TWAP conditional orders that will be used to dogfood the ComposableCoW
        IConditionalOrder.ConditionalOrderParams[] memory _leaves = getBundle(safe1, 50);

        // 2. Do the merkle tree dance
        (bytes32 root, bytes32[] memory proof, IConditionalOrder.ConditionalOrderParams memory leaf) =
            _leaves.getRootAndProof(0, leaves, getRoot, getProof);

        // 3. Set the root
        _setRoot(address(safe1), root, ComposableCoW.Proof({location: 0, data: ""}));

        // 4. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), leaf, hex"", proof);

        // 5. Execute the order
        settle(address(safe1), bob, order, signature, hex"");
    }

    /**
     * @notice A full e2e test from order creation to settlement.
     * @dev This is a very expensive test as it iterates over every second for
     *     the duration of the TWAP order.
     * @param numParts The number of parts in the TWAP order
     * @param frequency The frequency of the TWAP order
     * @param span The span of the TWAP order
     */
    function test_simulate_fuzz(uint32 numParts, uint32 frequency, uint32 span) public {
        // guard against underflows
        vm.assume(span < frequency);
        // guard against reversions
        numParts = uint32(bound(numParts, 2, type(uint32).max));
        frequency = uint32(bound(frequency, 120, type(uint32).max));
        // provide some sane limits to avoid out of gas on test issues
        vm.assume(
            span == 0
                ? uint256(numParts) * uint256(frequency) < 1 hours
                : uint256(numParts) * uint256(span) + (uint256(numParts) * uint256(frequency - span) * 3) < 4 hours
        );

        // Assemble the TWAP bundle
        TWAPOrder.Data memory bundle = _twapTestBundle(block.timestamp);
        bundle.n = numParts;
        bundle.t = frequency;
        bundle.span = span;

        // Deal the tokens to the safe and the user
        deal(address(bundle.sellToken), address(safe1), bundle.partSellAmount * bundle.n);
        deal(address(bundle.buyToken), bob.addr, bundle.minPartLimit * bundle.n);

        // Record balances before the simulation starts
        uint256 safeSellTokenBalance = IERC20(bundle.sellToken).balanceOf(address(safe1));
        uint256 safeBuyTokenBalance = IERC20(bundle.buyToken).balanceOf(address(safe1));
        uint256 bobBuyTokenBalance = IERC20(bundle.sellToken).balanceOf(bob.addr);
        uint256 bobSellTokenBalance = IERC20(bundle.buyToken).balanceOf(bob.addr);

        // Create the order
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrder(safe1, bundle, bundle.sellToken, bundle.partSellAmount * bundle.n);

        uint256 totalFills;
        uint256 numSecsProcessed;

        // Warp to the start of the TWAP
        vm.warp(bundle.t0);

        // calculate the ending time
        uint256 endTime = bundle.t0 + (bundle.n * bundle.t);

        while (true) {
            // Simulate being called by the watch tower

            try composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", new bytes32[](0)) returns (
                GPv2Order.Data memory order, bytes memory signature
            ) {
                bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
                if (
                    orderFills[orderDigest] == 0
                        && ExtensibleFallbackHandler(address(safe1)).isValidSignature(orderDigest, signature)
                            == ERC1271.isValidSignature.selector
                ) {
                    // Have a new order, so let's settle it
                    settle(address(safe1), bob, order, signature, hex"");

                    orderFills[orderDigest] = 1;
                    totalFills++;
                }

                // only count this second if we didn't revert
                numSecsProcessed++;
            } catch (bytes memory lowLevelData) {
                bytes4 receivedSelector = bytes4(lowLevelData);

                // Should have reverted if the `numSecsProcessed` > `frequency * numParts`
                if (block.timestamp == endTime && receivedSelector == IConditionalOrder.OrderNotValid.selector) {
                    break;
                } else if (block.timestamp > endTime) {
                    revert("OrderNotValid() should have been thrown");
                }

                // The order should always be valid because there is no span
                if (span == 0 && receivedSelector == IConditionalOrder.OrderNotValid.selector) {
                    revert("OrderNotValid() should not be thrown");
                }
            }
            vm.warp(block.timestamp + 1 seconds);
        }

        // the timestamp should be equal to the end time of the TWAP order
        assertTrue(block.timestamp == bundle.t0 + bundle.n * bundle.t, "TWAP order should be expired");
        // the number of seconds processed should be equal to the number of
        // parts times span (if span is not 0)
        assertTrue(
            numSecsProcessed == ((span == 0) ? bundle.n * bundle.t : bundle.n * bundle.span),
            "Number of seconds processed is incorrect"
        );
        // the number of fills should be equal to the number of parts
        assertTrue(totalFills == bundle.n, "Number of fills is incorrect");

        // Verify that balances are as expected after the simulation
        assertTrue(
            IERC20(bundle.sellToken).balanceOf(address(safe1))
                == safeSellTokenBalance - bundle.partSellAmount * bundle.n,
            "TWAP safe sell token balance is incorrect"
        );
        assertTrue(
            IERC20(bundle.buyToken).balanceOf(address(safe1)) >= safeBuyTokenBalance + bundle.minPartLimit * bundle.n,
            "TWAP safe buy token balance is incorrect"
        );
        assertTrue(
            IERC20(bundle.sellToken).balanceOf(bob.addr) == bobBuyTokenBalance + bundle.partSellAmount * bundle.n,
            "Bob buy token balance is incorrect"
        );
        assertTrue(
            IERC20(bundle.buyToken).balanceOf(bob.addr) >= bobSellTokenBalance - bundle.minPartLimit * bundle.n,
            "Bob sell token balance is incorrect"
        );
    }

    /**
     * @dev Fuzz test `calculateValidTo` function
     * @param currentTime The current time
     * @param startTime The start time of the TWAP order
     * @param numParts The number of parts in the TWAP order
     * @param frequency The frequency of the TWAP order
     * @param span The span of the TWAP order
     */
    function test_TWAPOrderMathLib_calculateValidTo(
        uint256 currentTime,
        uint256 startTime,
        uint256 numParts,
        uint256 frequency,
        uint256 span
    ) public {
        // --- Implicit assumptions
        // `currentTime` is always set to the `block.timestamp` in the TWAP order, so we can assume that it is less
        // than the max uint32 value.
        vm.assume(currentTime <= type(uint32).max);

        // --- Assertions
        // number of parts is asserted to be less than the max uint32 value in the TWAP order, so we can assume that
        // it is less than the max uint32 value.
        numParts = bound(numParts, 2, type(uint32).max);

        // frequency is asserted to be less than 365 days worth of seconds in the TWAP order, and at least 1 second
        frequency = bound(frequency, 1, 365 days);

        // The span is defined as the number of seconds that the TWAP order is valid for within each period. If the
        // span is 0, then the TWAP order is valid for the entire period. We can assume that the span is less than or
        // equal to the frequency.
        vm.assume(span <= frequency);

        // --- In-function revert conditions
        // We only calculate `validTo` if we are within the TWAP order's time window, so we can assume that the current
        // time is greater than or equal to the start time.
        vm.assume(currentTime >= startTime);

        // The TWAP order is deemed expired if the current time is greater than the end time of the last part. We can
        // assume that the current time is less than the end time of the TWAP order.
        vm.assume(currentTime < startTime + (numParts * frequency));

        uint256 part = (currentTime - startTime) / frequency;

        // The TWAP order is only valid for the span within each period, so we can assume that the current time is less
        // than the end time of the current part.
        vm.assume(currentTime < startTime + ((part + 1) * frequency) - (span != 0 ? (frequency - span) : 0));

        // --- Warp to the current time
        vm.warp(currentTime);

        uint256 validTo = TWAPOrderMathLib.calculateValidTo(startTime, numParts, frequency, span);

        uint256 expectedValidTo = startTime + ((part + 1) * frequency) - (span != 0 ? (frequency - span) : 0) - 1;

        // `validTo` MUST be now or in the future.
        assertTrue(validTo >= currentTime);
        // `validTo` MUST be equal to this.
        assertTrue(validTo == expectedValidTo);
    }

    // --- Helper functions ---

    function createOrder(Safe safe, TWAPOrder.Data memory twapBundle, IERC20 sellToken, uint256 sellAmount)
        internal
        returns (IConditionalOrder.ConditionalOrderParams memory params)
    {
        params = super.createOrder(twap, keccak256("twap"), abi.encode(twapBundle));

        // create the order
        _create(address(safe), params, false);
        // deal the sell token to the safe
        deal(address(sellToken), address(safe), sellAmount);
        // authorize the vault relayer to pull the sell token from the safe
        vm.prank(address(safe));
        sellToken.approve(address(relayer), sellAmount);
    }

    function createOrderWithContext(
        Safe safe,
        TWAPOrder.Data memory twapBundle,
        IERC20 sellToken,
        uint256 sellAmount,
        IValueFactory factory,
        bytes memory data
    ) internal returns (IConditionalOrder.ConditionalOrderParams memory params) {
        params = super.createOrder(twap, keccak256("twap"), abi.encode(twapBundle));

        // create the order
        _createWithContext(address(safe), params, factory, data, false);
        // deal the sell token to the safe
        deal(address(sellToken), address(safe), sellAmount);
        // authorize the vault relayer to pull the sell token from the safe
        vm.prank(address(safe));
        sellToken.approve(address(relayer), sellAmount);
    }

    function _twapTestBundle(uint256 startTime) internal view returns (TWAPOrder.Data memory) {
        return TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0), // the safe itself
            partSellAmount: SELL_AMOUNT / NUM_PARTS,
            minPartLimit: LIMIT_PRICE,
            t0: startTime,
            n: NUM_PARTS,
            t: FREQUENCY,
            span: SPAN,
            appData: keccak256("test.twap")
        });
    }
}
