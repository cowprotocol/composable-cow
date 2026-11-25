// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Signing, GPv2Trade, GPv2Interaction} from "cowprotocol/contracts/GPv2Settlement.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {Safe, Enum} from "safe/Safe.sol";
import {ERC1271} from "safe/handler/extensible/SignatureVerifierMuxer.sol";
import {INVALID_HASH} from "src/BaseConditionalOrder.sol";
import {ComposableCoW} from "src/ComposableCoW.sol";
import {FeeTokenSwap} from "src/types/FeeTokenSwap.sol";
import {BaseComposableCoWTest, GPv2Order, IConditionalOrder} from "./ComposableCoW.base.t.sol";
import {MockCowShed, MockCowShedFactory, MockShedCall} from "./helpers/CowShed.t.sol";
import {MockERC20} from "./helpers/Tokens.t.sol";
import {SafeLib} from "./libraries/SafeLib.t.sol";
import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";
import {GPv2TradeEncoder} from "./vendored/GPv2TradeEncoder.sol";

contract FeeTokenSwapTest is BaseComposableCoWTest {
    using SafeLib for Safe;

    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address owner,bytes32 orderId,uint256 sellAmount,uint256 minBuyAmount,uint32 issuedAt,uint32 validTo)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    FeeTokenSwap private feeTokenSwap;
    FeeTokenSwap.Data private settings;
    TestAccount private pricingSigner;
    address private shed;

    function setUp() public override {
        super.setUp();
        vm.warp(1_700_000_000);
        feeTokenSwap = new FeeTokenSwap();
        pricingSigner = TestAccountLib.createTestAccount("fee batch pricing");
        shed = (new MockCowShedFactory(composableCow)).initializeProxy(alice.addr);
        settings = FeeTokenSwap.Data(token0, token1, carol.addr, pricingSigner.addr, 100e18, keccak256("{}"), 300);
        deal(address(token0), shed, 120e18);
    }

    function test_acceptsExactTokenMinimumAndOwnerCanRemoveForBothAccounts() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        address[2] memory owners = [address(safe1), shed];
        for (uint256 i; i < owners.length; ++i) {
            address owner = owners[i];
            _register(owner, params);
            (GPv2Order.Data memory order, bytes memory signature) =
                _get(owner, params, _sign(owner, params, _quote(100e18), pricingSigner));
            bytes32 digest = GPv2Order.hash(order, settlement.domainSeparator());
            assertEq(bytes32(ERC1271(owner).isValidSignature(digest, signature)), bytes32(bytes4(0x1626ba7e)));
            assertEq(order.sellAmount, 100e18);
            assertEq(order.buyAmount, 990e18);

            _removeOrder(owner, params);
            vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
            ERC1271(owner).isValidSignature(digest, signature);
        }
    }

    function test_emptyQuoteTellsWatchtowerToKeepWatching() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(shed, params);
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalOrder.PollTryNextBlock.selector, "Fee swap needs a signed quote")
        );
        _get(shed, params, "");
    }

    function test_rejectsBelowTokenMinimum() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(shed, params);
        _expectInvalid(params, _quote(99e18), pricingSigner, "sell amount below minimum");
    }

    function test_rejectsQuoteForDifferentSignerOwnerOrOrderId() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(shed, params);
        FeeTokenSwap.Quote memory quote = _quote(100e18);
        _expectInvalid(params, quote, alice, "invalid pricing signature");
        bytes memory otherOwnerQuote = _sign(address(safe1), params, quote, pricingSigner);
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "invalid pricing signature"));
        _get(shed, params, otherOwnerQuote);

        bytes memory input = _sign(shed, params, quote, pricingSigner);
        (GPv2Order.Data memory order, bytes memory signature) = _get(shed, params, input);
        IConditionalOrder.ConditionalOrderParams memory newParams = _params(settings);
        newParams.salt = bytes32(uint256(2));
        _removeOrder(shed, params);
        _register(shed, newParams);
        bytes32 digest = GPv2Order.hash(order, settlement.domainSeparator());
        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        ERC1271(shed).isValidSignature(digest, signature);
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "invalid pricing signature"));
        _get(shed, newParams, input);
        (order,) = _get(shed, newParams, _sign(shed, newParams, quote, pricingSigner));
        assertEq(order.sellAmount, 100e18);
    }

    function test_requiresSingleConditionalOrder() public {
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "single conditional order required")
        );
        feeTokenSwap.getTradeableOrder(shed, address(this), bytes32(0), abi.encode(settings), "");
    }

    function test_rejectsFutureExpiredOverlongZeroOutputAndInsufficientBalance() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(shed, params);
        FeeTokenSwap.Quote memory quote = _quote(121e18);
        _expectInvalid(params, quote, pricingSigner, "insufficient sell token balance");
        quote.sellAmount = 120e18;
        quote.minBuyAmount = 0;
        _expectInvalid(params, quote, pricingSigner, "zero minimum buy amount");
        quote.minBuyAmount = 990e18;
        quote.issuedAt++;
        _expectInvalid(params, quote, pricingSigner, "invalid quote lifetime");
        quote.issuedAt--;
        quote.validTo++;
        _expectInvalid(params, quote, pricingSigner, "invalid quote lifetime");
        quote.validTo--;
        vm.warp(quote.validTo);
        _get(shed, params, _sign(shed, params, quote, pricingSigner));
        vm.warp(block.timestamp + 1);
        _expectInvalid(params, quote, pricingSigner, "invalid quote lifetime");
    }

    function test_usesBaseUnitsForSecondToken() public {
        FeeTokenSwap.Data memory sixDecimals = settings;
        sixDecimals.sellToken = IERC20(address(new SixDecimalToken()));
        sixDecimals.minSellAmount = 100e6;
        deal(address(sixDecimals.sellToken), shed, 100e6);
        IConditionalOrder.ConditionalOrderParams memory params = _params(sixDecimals);
        _register(shed, params);
        _expectInvalid(params, _quote(99e6), pricingSigner, "sell amount below minimum");
        (GPv2Order.Data memory order,) = _get(shed, params, _sign(shed, params, _quote(100e6), pricingSigner));
        assertEq(address(order.sellToken), address(sixDecimals.sellToken));
        assertEq(order.sellAmount, 100e6);
    }

    function test_settlesExactQuoteAfterMoreFundsArrive() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(address(safe1), params);
        deal(address(token0), address(safe1), 120e18);
        (GPv2Order.Data memory order, bytes memory signature) =
            _get(address(safe1), params, _sign(address(safe1), params, _quote(120e18), pricingSigner));
        assertEq(order.buyAmount, 990e18);
        assertEq(order.receiver, carol.addr);
        assertEq(order.appData, settings.appData);
        assertEq(order.feeAmount, 0);
        assertFalse(order.partiallyFillable);

        vm.prank(alice.addr);
        assertTrue(token0.transfer(address(safe1), 10e18));
        _approve(address(safe1));
        settle(address(safe1), bob, order, signature, bytes4(0));
        assertEq(token0.balanceOf(address(safe1)), 10e18);
        assertEq(token1.balanceOf(carol.addr), 990e18);
    }

    function test_settlementRejectsClearingPriceBelowFloor() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(shed, params);
        (GPv2Order.Data memory order, bytes memory signature) =
            _get(shed, params, _sign(shed, params, _quote(120e18), pricingSigner));
        _approve(shed);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 989e18;
        prices[1] = 120e18;
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data(
            0,
            1,
            order.receiver,
            order.sellAmount,
            order.buyAmount,
            order.validTo,
            order.appData,
            order.feeAmount,
            GPv2TradeEncoder.encodeFlags(order, GPv2Signing.Scheme.Eip1271),
            0,
            abi.encodePacked(shed, signature)
        );
        GPv2Interaction.Data[][3] memory interactions =
            [new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0)];
        vm.prank(solver.addr);
        vm.expectRevert("GPv2: limit price not respected");
        settlement.settle(tokens, prices, trades, interactions);
        assertEq(token0.balanceOf(shed), 120e18);
    }

    function test_rejectsChangedOrderTermsAndSignedQuote() public {
        IConditionalOrder.ConditionalOrderParams memory params = _params(settings);
        _register(shed, params);
        FeeTokenSwap.Quote memory quote = _quote(120e18);
        bytes memory input = _sign(shed, params, quote, pricingSigner);
        (GPv2Order.Data memory order, bytes memory signature) = _get(shed, params, input);
        (, ComposableCoW.PayloadStruct memory payload) =
            abi.decode(signature, (GPv2Order.Data, ComposableCoW.PayloadStruct));
        order.receiver = bob.addr;
        bytes32 digest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory changedOrderSignature = abi.encode(order, payload);
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_HASH));
        ERC1271(shed).isValidSignature(digest, changedOrderSignature);

        (, bytes32 r, bytes32 vs) = abi.decode(input, (FeeTokenSwap.Quote, bytes32, bytes32));
        quote.minBuyAmount--;
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "invalid pricing signature"));
        _get(shed, params, abi.encode(quote, r, vs));
    }

    function _register(address owner, IConditionalOrder.ConditionalOrderParams memory params) private {
        _ownerCall(owner, address(composableCow), abi.encodeCall(composableCow.create, (params, false)));
        assertTrue(composableCow.singleOrders(owner, composableCow.hash(params)));
    }

    function _removeOrder(address owner, IConditionalOrder.ConditionalOrderParams memory params) private {
        bytes32 conditionalOrderId = composableCow.hash(params);
        _ownerCall(owner, address(composableCow), abi.encodeCall(composableCow.remove, (conditionalOrderId)));
        assertFalse(composableCow.singleOrders(owner, conditionalOrderId));
    }

    function _approve(address owner) private {
        _ownerCall(owner, address(token0), abi.encodeCall(token0.approve, (relayer, type(uint256).max)));
    }

    function _ownerCall(address owner, address target, bytes memory data) private {
        if (owner == address(safe1)) {
            safe1.execute(target, 0, data, Enum.Operation.Call, signers());
        } else {
            MockShedCall[] memory calls = new MockShedCall[](1);
            calls[0] = MockShedCall(target, 0, data);
            vm.prank(alice.addr);
            MockCowShed(payable(owner)).trustedExecuteHooks(calls);
        }
    }

    function _params(FeeTokenSwap.Data memory data)
        private
        view
        returns (IConditionalOrder.ConditionalOrderParams memory)
    {
        return createOrder(feeTokenSwap, bytes32(uint256(1)), abi.encode(data));
    }

    function _quote(uint256 sell) private view returns (FeeTokenSwap.Quote memory) {
        return FeeTokenSwap.Quote(sell, 990e18, uint32(block.timestamp), uint32(block.timestamp + 300));
    }

    function _sign(
        address owner,
        IConditionalOrder.ConditionalOrderParams memory params,
        FeeTokenSwap.Quote memory quote,
        TestAccount memory signer
    ) private view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("FeeTokenSwap"), keccak256("2"), block.chainid, address(feeTokenSwap))
        );
        bytes32 quoteHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                owner,
                composableCow.hash(params),
                quote.sellAmount,
                quote.minBuyAmount,
                quote.issuedAt,
                quote.validTo
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.pk, keccak256(abi.encodePacked(hex"1901", domain, quoteHash)));
        bytes32 vs = s | (bytes32(uint256(v - 27)) << 255);
        return abi.encode(quote, r, vs);
    }

    function _expectInvalid(
        IConditionalOrder.ConditionalOrderParams memory params,
        FeeTokenSwap.Quote memory quote,
        TestAccount memory signer,
        string memory reason
    ) private {
        bytes memory input = _sign(shed, params, quote, signer);
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, reason));
        _get(shed, params, input);
    }

    function _get(address owner, IConditionalOrder.ConditionalOrderParams memory params, bytes memory input)
        private
        view
        returns (GPv2Order.Data memory, bytes memory)
    {
        return composableCow.getTradeableOrderWithSignature(owner, params, input, new bytes32[](0));
    }
}

contract SixDecimalToken is MockERC20 {
    constructor() MockERC20("Six decimal token", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
