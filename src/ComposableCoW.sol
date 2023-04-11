// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Safe} from "safe/Safe.sol";
import {ISafeSignatureVerifier, ERC1271} from "safe/handler/SignatureVerifierMuxer.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {ConditionalOrder} from "./interfaces/ConditionalOrder.sol";

contract ComposableCoW is ISafeSignatureVerifier {
    // A mapping of user's merkle roots
    mapping(Safe => bytes32) public roots;

    // An enum representing different ways to store proofs
    enum ProofStorage {
        None,
        Emit,
        Swarm,
        IPFS
    }

    // A struct representing where to find the proofs
    struct Proof {
        ProofStorage storageType;
        bytes payload;
    }

    // A struct representing the conditional order's parameters
    struct ConditionalOrderParams {
        ConditionalOrder handler;
        bytes32 salt;
        bytes data;
    }

    // An event emitted when a user sets their merkle root
    event RootSet(address indexed usr, bytes32 root, Proof proof);

    /// @notice Set the merkle root of the user's conditional orders
    /// @param root The merkle root of the user's conditional orders
    /// @param proof Where to find the proofs
    function setRoot(bytes32 root, Proof calldata proof) external {
        roots[Safe(payable(msg.sender))] = root;
        emit RootSet(msg.sender, root, proof);
    }

    function isValidSafeSignature(Safe safe, address sender, bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4 magic)
    {
        // The signature is an abi.encode(bytes32[] proof, ConditionalOrderParams orderParams, GPV2Order.Data)
        (bytes32[] memory proof, ConditionalOrderParams memory params, GPv2Order.Data memory order) =
            abi.decode(signature, (bytes32[], ConditionalOrderParams, GPv2Order.Data));

        // Computing proof using leaf double hashing
        // https://flawed.net.nz/2018/02/21/attacking-merkle-trees-with-a-second-preimage-attack/
        bytes32 root = roots[safe];
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(params))));

        // Verify the proof
        require(MerkleProof.verify(proof, root, leaf), "ComposableCow: invalid proof");

        // The proof is valid, so now check if the order is valid
        if (params.handler.verify(address(safe), sender, hash, ConditionalOrder.PayloadStruct({order: order, data: params.data}))) {
            magic = ERC1271.isValidSignature.selector;
        }
    }
}
