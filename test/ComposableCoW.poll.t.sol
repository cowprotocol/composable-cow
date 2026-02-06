// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    ComposableCoW,
    BaseComposableCoWTest,
    OrderNotValidHandler,
    PollTryNextBlockHandler,
    PollTryAtTimestampHandler,
    PollTryAtBlockHandler,
    SuccessHandler
} from "./ComposableCoW.base.t.sol";

/// @title Tests for poll() function and error decoding in BaseConditionalOrder
contract ComposableCoWPollTest is BaseComposableCoWTest {
    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();
    }

    /// @dev Test that OrderNotValid error is decoded to INVALID PollResult
    function test_poll_DecodesOrderNotValid() public {
        string memory expectedReason = "order is invalid";
        OrderNotValidHandler handler = new OrderNotValidHandler(expectedReason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.INVALID));
        assertEq(result.reason, expectedReason);
        assertEq(result.waitUntil, 0);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev Test that PollTryNextBlock error is decoded to TRY_NEXT_BLOCK PollResult
    function test_poll_DecodesPollTryNextBlock() public {
        string memory expectedReason = "try next block";
        PollTryNextBlockHandler handler = new PollTryNextBlockHandler(expectedReason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.TRY_NEXT_BLOCK));
        assertEq(result.reason, expectedReason);
        assertEq(result.waitUntil, 0);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev Test that PollTryAtTimestamp error is decoded to WAIT_TIMESTAMP PollResult
    function test_poll_DecodesPollTryAtTimestamp() public {
        uint256 expectedTimestamp = 1234567890;
        string memory expectedReason = "wait for timestamp";
        PollTryAtTimestampHandler handler = new PollTryAtTimestampHandler(expectedTimestamp, expectedReason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.WAIT_TIMESTAMP));
        assertEq(result.reason, expectedReason);
        assertEq(result.waitUntil, expectedTimestamp);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev Test that PollTryAtBlock error is decoded to WAIT_BLOCK PollResult
    function test_poll_DecodesPollTryAtBlock() public {
        uint256 expectedBlock = 999999;
        string memory expectedReason = "wait for block";
        PollTryAtBlockHandler handler = new PollTryAtBlockHandler(expectedBlock, expectedReason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.WAIT_BLOCK));
        assertEq(result.reason, expectedReason);
        assertEq(result.waitUntil, expectedBlock);
        assertEq(result.nextPollTimestamp, 0);
    }

    /// @dev Test that successful generateOrder returns SUCCESS PollResult
    function test_poll_ReturnsSuccessOnValidOrder() public {
        SuccessHandler handler = new SuccessHandler();

        GPv2Order.Data memory expectedOrder = GPv2Order.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: keccak256("test"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        handler.setOrder(expectedOrder);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.SUCCESS));
        assertEq(result.reason, "order ready");
        assertEq(address(result.order.sellToken), address(expectedOrder.sellToken));
        assertEq(address(result.order.buyToken), address(expectedOrder.buyToken));
        assertEq(result.order.sellAmount, expectedOrder.sellAmount);
        assertEq(result.order.buyAmount, expectedOrder.buyAmount);
    }

    /// @dev Fuzz test OrderNotValid error decoding
    function test_poll_FuzzOrderNotValid(string memory reason) public {
        OrderNotValidHandler handler = new OrderNotValidHandler(reason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.INVALID));
        assertEq(result.reason, reason);
    }

    /// @dev Fuzz test PollTryAtTimestamp error decoding
    function test_poll_FuzzPollTryAtTimestamp(uint256 timestamp, string memory reason) public {
        PollTryAtTimestampHandler handler = new PollTryAtTimestampHandler(timestamp, reason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.WAIT_TIMESTAMP));
        assertEq(result.waitUntil, timestamp);
        assertEq(result.reason, reason);
    }

    /// @dev Fuzz test PollTryAtBlock error decoding
    function test_poll_FuzzPollTryAtBlock(uint256 blockNum, string memory reason) public {
        PollTryAtBlockHandler handler = new PollTryAtBlockHandler(blockNum, reason);

        IConditionalOrderGenerator.PollResult memory result =
            handler.poll(address(safe1), address(this), bytes32(0), bytes(""), bytes(""));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.WAIT_BLOCK));
        assertEq(result.waitUntil, blockNum);
        assertEq(result.reason, reason);
    }

    /// @dev Test that getTradeableOrderWithSignature uses poll() internally and returns correct PollResult
    function test_getTradeableOrderWithSignature_UsesPollInternally() public {
        uint256 expectedTimestamp = block.timestamp + 1 days;
        string memory expectedReason = "too early";
        PollTryAtTimestampHandler handler = new PollTryAtTimestampHandler(expectedTimestamp, expectedReason);

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(handler)), salt: keccak256("test"), staticInput: bytes("")
        });

        _create(address(safe1), params, false);

        (IConditionalOrderGenerator.PollResult memory result,) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), new bytes32[](0));

        assertEq(uint256(result.code), uint256(IConditionalOrderGenerator.PollResultCode.WAIT_TIMESTAMP));
        assertEq(result.waitUntil, expectedTimestamp);
        assertEq(result.reason, expectedReason);
    }

    /// @dev Test that verify() uses generateOrder() and validates hash
    function test_verify_UsesGenerateOrder() public {
        SuccessHandler handler = new SuccessHandler();

        GPv2Order.Data memory expectedOrder = GPv2Order.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: keccak256("test"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        handler.setOrder(expectedOrder);

        bytes32 domainSeparator = composableCow.domainSeparator();
        bytes32 orderHash = GPv2Order.hash(expectedOrder, domainSeparator);

        // Should not revert - hash matches
        handler.verify(
            address(safe1), address(this), orderHash, domainSeparator, bytes32(0), bytes(""), bytes(""), expectedOrder
        );
    }

    /// @dev Test that verify() reverts on hash mismatch
    function test_verify_RevertsOnHashMismatch() public {
        SuccessHandler handler = new SuccessHandler();

        GPv2Order.Data memory expectedOrder = GPv2Order.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            sellAmount: 100e18,
            buyAmount: 50e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: keccak256("test"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
        handler.setOrder(expectedOrder);

        bytes32 domainSeparator = composableCow.domainSeparator();
        bytes32 wrongHash = keccak256("wrong hash");

        // Should revert - hash doesn't match
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, "invalid hash"));
        handler.verify(
            address(safe1), address(this), wrongHash, domainSeparator, bytes32(0), bytes(""), bytes(""), expectedOrder
        );
    }
}
