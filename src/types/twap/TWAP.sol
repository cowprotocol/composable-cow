// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "safe/Safe.sol";
import "safe/handler/extensible/SignatureVerifierMuxer.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import "../../interfaces/ConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";

/// @title CoW TWAP Fallback Handler
/// @author mfw78 <mfw78@rndlabs.xyz>
/// @dev A fallback handler to enable TWAP conditional orders on Safe, settling via CoW Protocol.
contract TWAP is ConditionalOrderFactory {

    bytes32 public immutable settlementDomainSeparator;
    constructor(bytes32 _settlementDomainSeparator) {
        settlementDomainSeparator = _settlementDomainSeparator;
    }

    function getTradeableOrder(
        address owner,
        address sender,
        bytes memory data
    ) public view override returns (PayloadStruct memory payload) {
        owner;
        sender;

        /// @dev Decode the payload into a TWAP bundle and get the order. `orderFor` will revert if
        /// there is no current valid order.
        /// NOTE: This will return an order even if the part of the TWAP bundle that is currently
        /// valid is filled. This is safe as CoW Protocol ensures that each `orderUid` is only
        /// settled once.
        payload.order = TWAPOrder.orderFor(abi.decode(data, (TWAPOrder.Data)));

        /// @dev Revert if the order is outside the TWAP bundle's span.
        if (!(block.timestamp <= payload.order.validTo))
            revert ConditionalOrder.OrderNotValid();
    }

    function isValidSafeSignature(
        Safe safe,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 typeHash,
        bytes calldata encodeData,
        bytes calldata payload
    ) external view override returns (bytes4 magic) {
        PayloadStruct memory p = abi.decode(payload, (PayloadStruct));
        GPv2Order.Data memory order = abi.decode(encodeData, (GPv2Order.Data));

        if (_hash != GPv2Order.hash(getTradeableOrder(address(safe), sender, p.data).order, domainSeparator)) {
            revert ConditionalOrder.OrderNotValid();
        } else {
            return ERC1271.isValidSignature.selector;
        }
    }

    function verify(
        address owner,
        address sender,
        bytes32 hash,
        PayloadStruct calldata payload
    ) external view override returns (bool) {
        // payload.order is disregarded as it is not used in the verification.
        PayloadStruct memory generatedOrder = getTradeableOrder(owner, sender, payload.data);

        /// @dev Verify that the order is valid and matches the payload.
        if (hash != GPv2Order.hash(generatedOrder.order, settlementDomainSeparator)) {
            revert ConditionalOrder.OrderNotValid();
        } else {
            return true;
        }
    }

    function dispatch(
        address safe,
        address sender,
        bytes calldata payload
    ) external override {}
}
