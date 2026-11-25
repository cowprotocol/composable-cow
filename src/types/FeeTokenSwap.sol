// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";

import {
    BaseConditionalOrder, GPv2Order, IConditionalOrder, IConditionalOrderGenerator
} from "../BaseConditionalOrder.sol";

/// @notice Sells one exact batch at a price authorized by the registered pricing signer.
contract FeeTokenSwap is BaseConditionalOrder, EIP712 {
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address owner,bytes32 orderId,uint256 sellAmount,uint256 minBuyAmount,uint32 issuedAt,uint32 validTo)"
    );

    /// @dev Encode as the conditional order's static input.
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        address pricingSigner;
        uint256 minSellAmount;
        bytes32 appData;
        uint32 maxQuoteLifetime;
    }

    /// @dev Token amounts use base units.
    struct Quote {
        uint256 sellAmount;
        uint256 minBuyAmount;
        uint32 issuedAt;
        uint32 validTo;
    }

    constructor() EIP712("FeeTokenSwap", "2") {}

    /// @inheritdoc IConditionalOrderGenerator
    function getTradeableOrder(
        address owner,
        address,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) public view override returns (GPv2Order.Data memory order) {
        // ComposableCoW passes hash(params) for single orders and zero for Merkle orders.
        if (ctx == bytes32(0)) revert IConditionalOrder.OrderNotValid("single conditional order required");
        if (offchainInput.length == 0) revert IConditionalOrder.PollTryNextBlock("Fee swap needs a signed quote");
        Data memory data = abi.decode(staticInput, (Data));
        (Quote memory quote, bytes32 r, bytes32 vs) = abi.decode(offchainInput, (Quote, bytes32, bytes32));

        if (quote.sellAmount == 0 || quote.sellAmount < data.minSellAmount) {
            revert IConditionalOrder.OrderNotValid("sell amount below minimum");
        }
        if (quote.minBuyAmount == 0) revert IConditionalOrder.OrderNotValid("zero minimum buy amount");
        if (
            quote.issuedAt > block.timestamp || quote.validTo < block.timestamp || quote.validTo <= quote.issuedAt
                || quote.validTo - quote.issuedAt > data.maxQuoteLifetime
        ) {
            revert IConditionalOrder.OrderNotValid("invalid quote lifetime");
        }

        _verifySignature(owner, ctx, quote, r, vs, data.pricingSigner);
        if (data.sellToken.balanceOf(owner) < quote.sellAmount) {
            revert IConditionalOrder.OrderNotValid("insufficient sell token balance");
        }

        order = GPv2Order.Data({
            sellToken: data.sellToken,
            buyToken: data.buyToken,
            receiver: data.receiver,
            sellAmount: quote.sellAmount,
            buyAmount: quote.minBuyAmount,
            validTo: quote.validTo,
            appData: data.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _verifySignature(
        address owner,
        bytes32 orderId,
        Quote memory quote,
        bytes32 r,
        bytes32 vs,
        address pricingSigner
    ) private view {
        bytes32 quoteDigest = _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, owner, orderId, quote)));
        (address signer, ECDSA.RecoverError error) = ECDSA.tryRecover(quoteDigest, r, vs);
        if (error != ECDSA.RecoverError.NoError || signer != pricingSigner) {
            revert IConditionalOrder.OrderNotValid("invalid pricing signature");
        }
    }
}
