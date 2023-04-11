// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Safe} from "safe/Safe.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {ISafeSignatureVerifier, ERC1271} from "safe/handler/SignatureVerifierMuxer.sol";

import {ConditionalOrder} from "./interfaces/ConditionalOrder.sol";

contract ComposableCoW is ISafeSignatureVerifier {
    // A mapping of user's merkle roots
    mapping(Safe => bytes32) public roots;
    bytes32 public immutable settlementDomainSeparator;

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

    // A struct representing how to check the price
    struct PriceCheckParams {
        IPriceChecker checker;
        bytes data;
    }

    // An event emitted when a user sets their merkle root
    event RootSet(address indexed usr, bytes32 root, Proof proof);

    constructor(bytes32 _settlementDomainSeparator) {
        settlementDomainSeparator = _settlementDomainSeparator;
    }

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
        // The signature is an abi.encode(bytes32[] proof, address orderHandler, bytes32 salt, bytes orderData)
        (
            bytes32[] memory proof,
            ConditionalOrderParams memory orderParams,
            PriceCheckParams memory checkerParams
        ) = abi.decode(signature, (bytes32[], ConditionalOrderParams, PriceCheckParams));

        // Computing proof using leaf double hashing
        // https://flawed.net.nz/2018/02/21/attacking-merkle-trees-with-a-second-preimage-attack/
        bytes32 root = roots[safe];
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(orderParams, checkerParams))));

        // Verify the proof
        require(MerkleProof.verify(proof, root, leaf), "ComposableCow: invalid proof");

        // The order is valid, so we can get the tradeable order
        GPv2Order.Data memory order = orderParams.handler.getTradeableOrder(address(safe), sender, orderParams.data);

        if (address(checkerParams.checker) != address(0)) {
            require(order.kind == GPv2Order.KIND_SELL, "ComposableCow: only sell orders can be price checked");
            require(order.partiallyFillable == false, "ComposableCow: only fully fillable orders can be price checked");

            // Check the price
            require(
                checkerParams.checker.checkPrice(
                    order.sellAmount + order.feeAmount,
                    address(order.sellToken),
                    address(order.buyToken),
                    order.feeAmount,
                    order.buyAmount,
                    checkerParams.data
                ),
                "ComposableCow: price check failed"
            );
        }

        if (hash == GPv2Order.hash(order, settlementDomainSeparator)) {
            magic = ERC1271.isValidSignature.selector;
        }
    }
}
