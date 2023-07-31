// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ERC1271} from "safe/handler/extensible/SignatureVerifierMuxer.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import "./ComposableCoW.sol";

/**
 * @title ERC1271 Forwarder - An abstract contract that implements ERC1271 forwarding to ComposableCoW
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Designed to be extended from by a contract that wants to use ComposableCoW
 */
abstract contract ERC1271Forwarder is ERC1271 {
    ComposableCoW public immutable composableCoW;

    constructor(ComposableCoW _composableCoW) {
        composableCoW = _composableCoW;
    }

    // When the pre-image doesn't match the hash, revert with this error.
    error InvalidHash();

    /**
     * Re-arrange the request into something that ComposableCoW can understand
     * @param _hash GPv2Order.Data digest
     * @param signature The abi.encoded tuple of (GPv2Order.Data, ComposableCoW.PayloadStruct)
     */
    function isValidSignature(bytes32 _hash, bytes memory signature) public view override returns (bytes4) {
        (GPv2Order.Data memory order, ComposableCoW.PayloadStruct memory payload) =
            abi.decode(signature, (GPv2Order.Data, ComposableCoW.PayloadStruct));
        bytes32 domainSeparator = composableCoW.domainSeparator();
        if (!(GPv2Order.hash(order, domainSeparator) == _hash)) {
            revert InvalidHash();
        }

        return composableCoW.isValidSafeSignature(
            Safe(payable(address(this))), // owner
            msg.sender, // sender
            _hash, // GPv2Order digest
            domainSeparator, // GPv2Settlement domain separator
            bytes32(0), // typeHash (not used by ComposableCoW)
            abi.encode(order), // GPv2Order
            abi.encode(payload) // ComposableCoW.PayloadStruct
        );
    }
}
