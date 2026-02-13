// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {
    IConditionalOrder,
    GPv2Order,
    ComposableCoW,
    ComposableCoWLib,
    Safe,
    SafeLib,
    BaseComposableCoWTest
} from "./ComposableCoW.base.t.sol";

import {IOrderManifest} from "../src/interfaces/IOrderManifest.sol";
import {TWAP} from "../src/types/twap/TWAP.sol";
import {TWAPOrder} from "../src/types/twap/libraries/TWAPOrder.sol";
import {StopLoss} from "../src/types/StopLoss.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";
import {IConditionalOrderGenerator} from "../src/interfaces/IConditionalOrder.sol";
import {IAggregatorV3Interface} from "../src/interfaces/IAggregatorV3Interface.sol";
import {IERC20} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";
import {IValueFactory} from "../src/interfaces/IValueFactory.sol";

/// @dev Mock oracle for testing
contract MockOracle {
    int256 public price;
    uint8 internal _decimals;

    constructor(int256 _price, uint8 decimals_) {
        price = _price;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract ComposableCoWManifestTest is BaseComposableCoWTest {
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];
    using SafeLib for Safe;

    // Event for testing ConditionalOrderRemoved
    event ConditionalOrderRemoved(address indexed owner, bytes32 indexed orderHash);

    PerpetualStableSwap perpetualSwap;
    StopLoss stopLoss;
    TradeAboveThreshold tradeAboveThreshold;
    GoodAfterTime goodAfterTime;
    IValueFactory currentBlockTimestampFactory;

    uint256 constant SELL_AMOUNT = 24000e18;
    uint256 constant LIMIT_PRICE = 100e18;
    uint32 constant FREQUENCY = 1 hours;
    uint32 constant NUM_PARTS = 24;
    uint32 constant SPAN = 5 minutes;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        // Deploy order type contracts
        perpetualSwap = new PerpetualStableSwap();
        stopLoss = new StopLoss();
        tradeAboveThreshold = new TradeAboveThreshold();
        goodAfterTime = new GoodAfterTime();
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
    }

    // ============ ConditionalOrderRemoved Event Tests ============

    function test_remove_EmitsConditionalOrderRemoved() public {
        // Create a simple order
        IConditionalOrder.ConditionalOrderParams memory params = getPassthroughOrder();
        _create(address(safe1), params, false);

        bytes32 orderHash = keccak256(abi.encode(params));

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit ConditionalOrderRemoved(address(safe1), orderHash);

        // Remove the order
        vm.prank(address(safe1));
        composableCow.remove(orderHash);
    }

    function test_remove_FuzzEmitsEvent(address owner, bytes32 salt) public {
        vm.assume(owner != address(0));

        IConditionalOrder.ConditionalOrderParams memory params =
            createOrder(passThrough, salt, bytes(""));

        // Create order directly (not through _create since owner may not be a Safe)
        vm.prank(owner);
        composableCow.create(params, false);

        bytes32 orderHash = keccak256(abi.encode(params));

        vm.expectEmit(true, true, true, true);
        emit ConditionalOrderRemoved(owner, orderHash);

        vm.prank(owner);
        composableCow.remove(orderHash);
    }

    // ============ TWAP Manifest Tests ============

    function test_TWAP_getManifestInfo_ReturnsFiniteCardinality() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(block.timestamp);

        IOrderManifest.ManifestInfo memory info = twap.getManifestInfo(
            address(safe1), bytes32(0), abi.encode(twapData)
        );

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.FINITE));
        assertEq(info.totalOrders, NUM_PARTS);
    }

    function test_TWAP_getManifestPage_ReturnsAllParts() public {
        uint256 startTime = block.timestamp;
        TWAPOrder.Data memory twapData = _twapTestBundle(startTime);

        // Get all parts in one page
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, NUM_PARTS
        );

        assertEq(entries.length, NUM_PARTS);
        assertFalse(hasMore);

        // Verify each entry
        for (uint256 i = 0; i < entries.length; i++) {
            assertEq(entries[i].index, i);
            assertEq(entries[i].validFrom, startTime + (i * FREQUENCY));

            // Verify order parameters
            assertEq(address(entries[i].order.sellToken), address(token0));
            assertEq(address(entries[i].order.buyToken), address(token1));
            assertEq(entries[i].order.sellAmount, twapData.partSellAmount);
            assertEq(entries[i].order.buyAmount, twapData.minPartLimit);
        }
    }

    function test_TWAP_getManifestPage_Pagination() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(block.timestamp);

        // Get first 10 parts
        (IOrderManifest.ManifestEntry[] memory page1, bool hasMore1) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, 10
        );

        assertEq(page1.length, 10);
        assertTrue(hasMore1);
        assertEq(page1[0].index, 0);
        assertEq(page1[9].index, 9);

        // Get next 10 parts
        (IOrderManifest.ManifestEntry[] memory page2, bool hasMore2) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 10, 10
        );

        assertEq(page2.length, 10);
        assertTrue(hasMore2);
        assertEq(page2[0].index, 10);
        assertEq(page2[9].index, 19);

        // Get last 4 parts
        (IOrderManifest.ManifestEntry[] memory page3, bool hasMore3) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 20, 10
        );

        assertEq(page3.length, 4);
        assertFalse(hasMore3);
        assertEq(page3[0].index, 20);
        assertEq(page3[3].index, 23);
    }

    function test_TWAP_getManifestPage_UninitializedReturnsEmpty() public {
        // Create TWAP data with t0=0 (needs context to initialize)
        TWAPOrder.Data memory twapData = _twapTestBundle(0);

        // Without context being set, t0 remains 0
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, 10
        );

        assertEq(entries.length, 0);
        assertFalse(hasMore);
    }

    function test_TWAP_getManifestPage_WithContext() public {
        TWAPOrder.Data memory twapData = _twapTestBundle(0);
        uint256 contextTime = block.timestamp + 1 days;

        // Create order with context
        IConditionalOrder.ConditionalOrderParams memory params =
            createOrder(twap, keccak256("twap"), abi.encode(twapData));

        // Create with context
        vm.warp(contextTime);
        _createWithContext(address(safe1), params, currentBlockTimestampFactory, bytes(""), false);

        bytes32 ctx = composableCow.hash(params);

        // Get manifest using the context
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = twap.getManifestPage(
            address(safe1), ctx, abi.encode(twapData), bytes(""), 0, 5
        );

        assertEq(entries.length, 5);
        assertTrue(hasMore);
        // First entry should have validFrom = contextTime (what was stored in cabinet)
        assertEq(entries[0].validFrom, contextTime);
    }

    function test_TWAP_ManifestEntriesMatchGenerateOrder() public {
        uint256 startTime = block.timestamp;
        TWAPOrder.Data memory twapData = _twapTestBundle(startTime);

        // Get all manifest entries
        (IOrderManifest.ManifestEntry[] memory entries,) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, NUM_PARTS
        );

        // For each part, warp to its validFrom and verify generateOrder matches
        for (uint256 i = 0; i < entries.length; i++) {
            vm.warp(entries[i].validFrom);

            GPv2Order.Data memory generatedOrder = twap.generateOrder(
                address(safe1), address(0), bytes32(0), abi.encode(twapData), bytes("")
            );

            // Compare key fields
            assertEq(address(entries[i].order.sellToken), address(generatedOrder.sellToken));
            assertEq(address(entries[i].order.buyToken), address(generatedOrder.buyToken));
            assertEq(entries[i].order.sellAmount, generatedOrder.sellAmount);
            assertEq(entries[i].order.buyAmount, generatedOrder.buyAmount);
            assertEq(entries[i].order.validTo, generatedOrder.validTo);
        }
    }

    function test_TWAP_IsActive_DuringSpan() public {
        uint256 startTime = block.timestamp;
        TWAPOrder.Data memory twapData = _twapTestBundle(startTime);

        // Warp to middle of first part's span
        vm.warp(startTime + SPAN / 2);

        (IOrderManifest.ManifestEntry[] memory entries,) = twap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(twapData), bytes(""), 0, 3
        );

        assertTrue(entries[0].isActive);  // First part is active
        assertFalse(entries[1].isActive); // Second part not yet active
        assertFalse(entries[2].isActive); // Third part not yet active
    }

    // ============ Single-Shot Order Manifest Tests ============

    function test_BaseConditionalOrder_DefaultManifest_ReturnsFiniteOne() public {
        // passThrough inherits from BaseConditionalOrder which has default manifest
        IOrderManifest.ManifestInfo memory info = passThrough.getManifestInfo(
            address(safe1), bytes32(0), bytes("")
        );

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.FINITE));
        assertEq(info.totalOrders, 1);
    }

    function test_BaseConditionalOrder_DefaultManifestPage() public {
        GPv2Order.Data memory order = getBlankOrder();

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = passThrough.getManifestPage(
            address(safe1), bytes32(0), bytes(""), abi.encode(order), 0, 10
        );

        assertEq(entries.length, 1);
        assertFalse(hasMore);
        assertEq(entries[0].index, 0);
        assertEq(entries[0].validFrom, 0);
    }

    function test_BaseConditionalOrder_ManifestPage_OffsetSkipsOrder() public {
        GPv2Order.Data memory order = getBlankOrder();

        // Offset > 0 should return empty for single-shot orders
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = passThrough.getManifestPage(
            address(safe1), bytes32(0), bytes(""), abi.encode(order), 1, 10
        );

        assertEq(entries.length, 0);
        assertFalse(hasMore);
    }

    // ============ PerpetualStableSwap Manifest Tests ============

    function test_PerpetualStableSwap_ManifestReturnsUnbounded() public {
        PerpetualStableSwap.Data memory data = PerpetualStableSwap.Data({
            tokenA: token0,
            tokenB: token1,
            validityBucketSeconds: 300,
            halfSpreadBps: 50,
            appData: keccak256("perpetual")
        });

        IOrderManifest.ManifestInfo memory info = perpetualSwap.getManifestInfo(
            address(safe1), bytes32(0), abi.encode(data)
        );

        assertEq(uint256(info.cardinality), uint256(IOrderManifest.Cardinality.UNBOUNDED));
        assertEq(info.totalOrders, 0);
    }

    function test_PerpetualStableSwap_HasMoreAlwaysTrue() public {
        PerpetualStableSwap.Data memory data = PerpetualStableSwap.Data({
            tokenA: token0,
            tokenB: token1,
            validityBucketSeconds: 300,
            halfSpreadBps: 50,
            appData: keccak256("perpetual")
        });

        // Fund the safe
        deal(address(token0), address(safe1), 1000e18);

        (, bool hasMore) = perpetualSwap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        // Perpetual orders always have more
        assertTrue(hasMore);
    }

    function test_PerpetualStableSwap_ManifestPage_NotFunded() public {
        // Use a fresh address with no token balances
        address unfundedOwner = makeAddr("unfunded");

        PerpetualStableSwap.Data memory data = PerpetualStableSwap.Data({
            tokenA: token0,
            tokenB: token1,
            validityBucketSeconds: 300,
            halfSpreadBps: 50,
            appData: keccak256("perpetual")
        });

        // Don't fund the owner - order should fail to generate (both balances are 0)
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = perpetualSwap.getManifestPage(
            unfundedOwner, bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        // Empty entries but still hasMore (perpetual)
        assertEq(entries.length, 0);
        assertTrue(hasMore);
    }

    function test_PerpetualStableSwap_ManifestPage_WithBalance() public {
        PerpetualStableSwap.Data memory data = PerpetualStableSwap.Data({
            tokenA: token0,
            tokenB: token1,
            validityBucketSeconds: 300,
            halfSpreadBps: 50,
            appData: keccak256("perpetual")
        });

        // Fund the safe with tokenA
        deal(address(token0), address(safe1), 1000e18);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = perpetualSwap.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        assertEq(entries.length, 1);
        assertTrue(hasMore);
        assertEq(entries[0].index, 0);
        assertEq(address(entries[0].order.sellToken), address(token0));
        assertEq(entries[0].order.sellAmount, 1000e18);
    }

    // ============ StopLoss Manifest Tests ============

    function test_StopLoss_ManifestShowsOrderStructure() public {
        // Warp to a reasonable timestamp to avoid underflow in staleness check
        vm.warp(1700000000);

        // Create stop loss data - the manifest should show order structure
        // even if oracle conditions aren't met
        StopLoss.Data memory data = StopLoss.Data({
            sellToken: token0,
            buyToken: token1,
            sellAmount: 1000e18,
            buyAmount: 900e18,
            appData: keccak256("stoploss"),
            receiver: address(safe1),
            isSellOrder: true,
            isPartiallyFillable: false,
            validTo: uint32(block.timestamp + 1 days),
            sellTokenPriceOracle: IAggregatorV3Interface(address(new MockOracle(1e8, 18))),
            buyTokenPriceOracle: IAggregatorV3Interface(address(new MockOracle(1e8, 18))),
            strike: 0, // Strike of 0 means price ratio must be <= 0 (never true for positive prices)
            maxTimeSinceLastOracleUpdate: 1 hours
        });

        // Should return the order structure with isActive=false (strike not reached)
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = stopLoss.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        assertEq(entries.length, 1);
        assertFalse(hasMore);
        assertEq(entries[0].index, 0);
        assertEq(entries[0].validFrom, 0); // Condition-based
        assertFalse(entries[0].isActive); // Strike not reached
        assertEq(entries[0].order.sellAmount, 1000e18);
        assertEq(entries[0].order.buyAmount, 900e18);
    }

    function test_StopLoss_ManifestReturnsEmptyWhenExpired() public {
        // Create expired stop loss data
        StopLoss.Data memory data = StopLoss.Data({
            sellToken: token0,
            buyToken: token1,
            sellAmount: 1000e18,
            buyAmount: 900e18,
            appData: keccak256("stoploss"),
            receiver: address(0),
            isSellOrder: true,
            isPartiallyFillable: false,
            validTo: uint32(block.timestamp - 1), // Already expired
            sellTokenPriceOracle: IAggregatorV3Interface(address(0)),
            buyTokenPriceOracle: IAggregatorV3Interface(address(0)),
            strike: 1e18,
            maxTimeSinceLastOracleUpdate: 1 hours
        });

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = stopLoss.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        assertEq(entries.length, 0);
        assertFalse(hasMore);
    }

    // ============ GoodAfterTime Manifest Tests ============

    function test_GoodAfterTime_ManifestSetsValidFromToStartTime() public {
        uint256 startTime = block.timestamp + 1 hours;
        uint256 endTime = block.timestamp + 2 hours;

        GoodAfterTime.Data memory data = GoodAfterTime.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 1000e18,
            minSellBalance: 500e18,
            startTime: startTime,
            endTime: endTime,
            allowPartialFill: false,
            priceCheckerPayload: bytes(""),
            appData: keccak256("gat")
        });

        // Fund the safe
        deal(address(token0), address(safe1), 1000e18);

        // Warp to after startTime
        vm.warp(startTime + 1);

        // Get manifest with offchainInput for buyAmount
        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = goodAfterTime.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), abi.encode(uint256(800e18)), 0, 10
        );

        assertEq(entries.length, 1);
        assertFalse(hasMore);
        assertEq(entries[0].validFrom, startTime);
        assertTrue(entries[0].isActive);
    }

    function test_GoodAfterTime_ManifestShowsInactiveBeforeStartTime() public {
        uint256 startTime = block.timestamp + 1 hours;
        uint256 endTime = block.timestamp + 2 hours;

        GoodAfterTime.Data memory data = GoodAfterTime.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 1000e18,
            minSellBalance: 500e18,
            startTime: startTime,
            endTime: endTime,
            allowPartialFill: false,
            priceCheckerPayload: bytes(""),
            appData: keccak256("gat")
        });

        // Fund the safe
        deal(address(token0), address(safe1), 1000e18);

        // Don't warp - still before startTime
        // generateOrder will revert with PollTryAtTimestamp, so manifest returns empty
        (IOrderManifest.ManifestEntry[] memory entries,) = goodAfterTime.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), abi.encode(uint256(800e18)), 0, 10
        );

        // Returns empty because generateOrder reverts before startTime
        assertEq(entries.length, 0);
    }

    // ============ TradeAboveThreshold Manifest Tests ============

    function test_TradeAboveThreshold_ManifestShowsOrderWhenBelowThreshold() public {
        TradeAboveThreshold.Data memory data = TradeAboveThreshold.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            validityBucketSeconds: 300,
            threshold: 1000e18,
            appData: keccak256("tat")
        });

        // Fund safe with less than threshold
        deal(address(token0), address(safe1), 500e18);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = tradeAboveThreshold.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        assertEq(entries.length, 1);
        assertFalse(hasMore);
        assertEq(entries[0].validFrom, 0); // Condition-based
        assertFalse(entries[0].isActive); // Below threshold
        // Shows threshold as sellAmount when below
        assertEq(entries[0].order.sellAmount, 1000e18);
    }

    function test_TradeAboveThreshold_ManifestShowsActiveWhenAboveThreshold() public {
        TradeAboveThreshold.Data memory data = TradeAboveThreshold.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            validityBucketSeconds: 300,
            threshold: 1000e18,
            appData: keccak256("tat")
        });

        // Fund safe with more than threshold
        deal(address(token0), address(safe1), 1500e18);

        (IOrderManifest.ManifestEntry[] memory entries, bool hasMore) = tradeAboveThreshold.getManifestPage(
            address(safe1), bytes32(0), abi.encode(data), bytes(""), 0, 10
        );

        assertEq(entries.length, 1);
        assertFalse(hasMore);
        assertTrue(entries[0].isActive); // Above threshold
        // Shows actual balance as sellAmount when above
        assertEq(entries[0].order.sellAmount, 1500e18);
    }

    // ============ Interface Support Tests ============

    function test_TWAP_SupportsIOrderManifest() public {
        assertTrue(twap.supportsInterface(type(IOrderManifest).interfaceId));
    }

    function test_TWAP_SupportsIConditionalOrderGenerator() public {
        assertTrue(twap.supportsInterface(type(IConditionalOrderGenerator).interfaceId));
    }

    function test_BaseConditionalOrder_SupportsIOrderManifest() public {
        assertTrue(passThrough.supportsInterface(type(IOrderManifest).interfaceId));
    }

    // ============ Helper Functions ============

    function _twapTestBundle(uint256 startTime) internal view returns (TWAPOrder.Data memory) {
        return TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
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
