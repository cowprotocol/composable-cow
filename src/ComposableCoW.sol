// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Safe} from "safe/Safe.sol";
import {ISafeSignatureVerifier, ERC1271} from "safe/handler/extensible/SignatureVerifierMuxer.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {ConditionalOrder} from "./interfaces/ConditionalOrder.sol";
import {ISwapGuard} from "./interfaces/ISwapGuard.sol";

contract ComposableCoW is ISafeSignatureVerifier {
    // A mapping of user's merkle roots
    mapping(Safe => bytes32) public roots;
    // TODO: Gas efficiency for packing storage variables
    mapping(Safe => ISwapGuard) public swapGuards;

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

    function isValidSafeSignature(
        Safe safe,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32, // typeHash
        bytes calldata encodeData,
        bytes calldata payload
    ) external view override returns (bytes4 magic) {
        // The signature is an abi.encode(bytes32[] proof, ConditionalOrderParams orderParams)
        (bytes32[] memory proof, ConditionalOrderParams memory params) =
            abi.decode(payload, (bytes32[], ConditionalOrderParams));

        // Scope to avoid stack too deep errors
        {
            // Computing proof using leaf double hashing
            // https://flawed.net.nz/2018/02/21/attacking-merkle-trees-with-a-second-preimage-attack/
            bytes32 root = roots[safe];
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(params))));

            // First, verify the proof
            require(MerkleProof.verify(proof, root, leaf), "ComposableCow: invalid proof");
        }

        // Scope to avoid stack too deep errors
        {
            // Decode the order
            GPv2Order.Data memory order = abi.decode(encodeData, (GPv2Order.Data));

            // Next check the guard (if any)
            ISwapGuard guard = swapGuards[safe];
            if (address(guard) != address(0)) {
                require(guard.verify(order, params.data), "ComposableCow: swap guard rejected");
            }

            // Proof is valid, guard (if any) is valid, now check the handler
            if (params.handler.verify(address(safe), sender, _hash, domainSeparator, order, params.data)) {
                magic = ERC1271.isValidSignature.selector;
            }
        }
    }
}
