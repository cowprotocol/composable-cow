// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import {Enum} from "safe/common/Enum.sol";
import {Safe} from "safe/Safe.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/interfaces/IERC20Metadata.sol";

import {ExtensibleFallbackHandler} from "safe/handler/ExtensibleFallbackHandler.sol";
import {SignatureVerifierMuxer, ERC1271} from "safe/handler/SignatureVerifierMuxer.sol";

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {Base} from "./Base.t.sol";
import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";
import {SafeLib} from "./libraries/SafeLib.t.sol";

import {TWAP, TWAPOrder} from "../src/types/twap/TWAP.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";

import {Merkle} from "murky/Merkle.sol";

contract ComposableCoWTest is Base, Merkle {
    using TestAccountLib for TestAccount[];
    using TestAccountLib for TestAccount;
    using SafeLib for Safe;

    ComposableCoW composableCow;
    TWAP twap;

    mapping(bytes32 => ComposableCoW.ConditionalOrderParams) public leaves;

    function setUp() public virtual override(Base) {
        // setup Base
        super.setUp();

        // set safe1 to have the ComposableCoW `ISafeSignatureVerifier` custom verifier
        // we will set the domainSeparator to settlement.domainSeparator()
        safe1.execute(
            address(svmSingleton),
            0,
            abi.encodeWithSelector(
                svmSingleton.setDomainVerifier.selector, settlement.domainSeparator(), address(composableCow)
            ),
            Enum.Operation.Call,
            signers()
        );

        // deploy composable cow
        composableCow = new ComposableCoW(settlement.domainSeparator());

        // deploy order types
        twap = new TWAP();

        // set custom verifier for safe1
        safe1.execute(
            address(svmSingleton),
            0,
            abi.encodeWithSelector(
                svmSingleton.setDomainVerifier.selector, settlement.domainSeparator(), address(composableCow)
            ),
            Enum.Operation.Call,
            signers()
        );
    }

    function test_setUp() public {
        // check that the ComposableCoW is the custom verifier for safe1
        assertEq(address(svmSingleton.domainVerifiers(safe1, settlement.domainSeparator())), address(composableCow));
    }

    function test_TWAP() public {
        // 1. Create a TWAP that will be used to dogfood some orders
        TWAPOrder.Data memory twapData = TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0),
            partSellAmount: 1,
            minPartLimit: 1,
            t0: block.timestamp,
            n: 2,
            t: 3600,
            span: 0
        });

        // 2. Create four conditional orders as leaves of the ComposableCoW
        ComposableCoW.ConditionalOrderParams[] memory _leaves = new ComposableCoW.ConditionalOrderParams[](4);
        for (uint256 i = 0; i < _leaves.length; i++) {
            _leaves[i] = ComposableCoW.ConditionalOrderParams({handler: twap, salt: bytes32(i), data: abi.encode(twapData)});

            leaves[hashLeaf(_leaves[i])] = _leaves[i];
        }

        // 3. Create keccak256 hashes of the leaves
        bytes32[] memory hashes = new bytes32[](_leaves.length);
        for (uint256 i = 0; i < _leaves.length; i++) {
            hashes[i] = hashLeaf(_leaves[i]);
        }

        // 4. Sort the hashes
        bytes32[] memory sortedHashes = sortBytes32Array(hashes);

        // 5. Create the Merkle root
        bytes32 root = getRoot(sortedHashes);

        // 6. Create the Merkle proof for the first leaf
        bytes32[] memory proof = getProof(sortedHashes, 0);

        // 7. Get the leaf that was used to create the proof
        ComposableCoW.ConditionalOrderParams memory leaf = leaves[sortedHashes[0]];

        // 8. Set the Merkle root
        safe1.execute(
            address(composableCow),
            0,
            abi.encodeWithSelector(
                composableCow.setRoot.selector,
                root,
                ComposableCoW.Proof({storageType: ComposableCoW.ProofStorage.None, payload: ""})
            ),
            Enum.Operation.Call,
            signers()
        );

        // 9. Construct the signature payload
        bytes memory data = abi.encodePacked(
            abi.encodeCall(
                ERC1271.isValidSignature,
                (
                    GPv2Order.hash(
                        twap.getTradeableOrder(address(safe1), address(0), leaf.data), settlement.domainSeparator()
                        ),
                    abi.encode(proof, leaf)
                )
            ),
            settlement.domainSeparator()
        );

        (bool success, bytes memory result) = address(safe1).staticcall(data);
        require(success, "failed to call isValidSignature");
    }

    function hashLeaf(ComposableCoW.ConditionalOrderParams memory leaf) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(leaf))));
    }

    function sortBytes32Array(bytes32[] memory array) public pure returns (bytes32[] memory) {
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
}
