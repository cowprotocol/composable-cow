// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Merkle} from "murky/Merkle.sol";
import {IConditionalOrder} from "../../src/interfaces/IConditionalOrder.sol";

library ComposableCoWLib {
    function hash(IConditionalOrder.ConditionalOrderParams memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(params))));
    }

    function sort(bytes32[] memory array) internal pure returns (bytes32[] memory) {
        for (uint256 i = 0; i < array.length; i++) {
            for (uint256 j = i + 1; j < array.length; j++) {
                if (array[i] > array[j]) {
                    bytes32 temp = array[i];
                    array[i] = array[j];
                    array[j] = temp;
                }
            }
        }
        return array;
    }

    /**
     * Generate a Merkle root and proof for a leaf in a tree
     * @param leaves to be inserted into the tree
     * @param n th leaf to generate the proof for
     * @param m a mapping of hashes to leaves to be populated (storage)
     * @param getRoot a function that returns the root of the tree given an array of hashes
     * @param getProof a function that returns the proof for a leaf given an array of hashes and the index of the leaf
     * @return the root of the tree
     * @return a proof for the n'th leaf
     * @return the n'th leaf
     */
    function getRootAndProof(
        IConditionalOrder.ConditionalOrderParams[] memory leaves,
        uint256 n,
        mapping(bytes32 => IConditionalOrder.ConditionalOrderParams) storage m,
        function (bytes32[] memory) internal pure returns (bytes32) getRoot,
        function (bytes32[] memory, uint256) internal pure returns (bytes32[] memory) getProof
    ) internal returns (bytes32, bytes32[] memory, IConditionalOrder.ConditionalOrderParams memory) {
        // 1. Create a mapping of hashes to leaves
        for (uint256 i = 0; i < leaves.length; i++) {
            m[hash(leaves[i])] = leaves[i];
        }

        // 2. Create keccak256 hashes of the leaves
        bytes32[] memory hashes = new bytes32[](leaves.length);
        for (uint256 i = 0; i < leaves.length; i++) {
            hashes[i] = hash(leaves[i]);
        }

        // 3. Sort the hashes
        bytes32[] memory sortedHashes = sort(hashes);

        // 4. Create the Merkle root
        bytes32 root = getRoot(sortedHashes);

        // 5. Create the Merkle proof for the n'th leaf
        bytes32[] memory proof = getProof(sortedHashes, n);

        // 6. Get the leaf that was used to create the proof
        IConditionalOrder.ConditionalOrderParams memory leaf = m[sortedHashes[n]];

        return (root, proof, leaf);
    }
}
