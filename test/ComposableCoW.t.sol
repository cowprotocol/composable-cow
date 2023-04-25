// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import {IERC20, IERC20Metadata} from "@openzeppelin/interfaces/IERC20Metadata.sol";
import {Merkle} from "murky/Merkle.sol";

import "safe/Safe.sol";
import "safe/handler/ExtensibleFallbackHandler.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

// Testing Libraries
import {Base} from "./Base.t.sol";
import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";
import {SafeLib} from "./libraries/SafeLib.t.sol";
import {ComposableCoWLib} from "./libraries/ComposableCoWLib.t.sol";

import {BaseSwapGuard} from "../src/guards/BaseSwapGuard.sol";

import {TWAP, TWAPOrder} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {IConditionalOrder} from "../src/interfaces/IConditionalOrder.sol";

import "../src/ComposableCoW.sol";

contract ComposableCoWTest is Base, Merkle {
    using TestAccountLib for TestAccount[];
    using TestAccountLib for TestAccount;
    using SafeLib for Safe;
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams;
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];

    event MerkleRootSet(address indexed owner, bytes32 root, ComposableCoW.Proof proof);
    event ConditionalOrderCreated(address indexed owner, IConditionalOrder.ConditionalOrderParams params);
    event SwapGuardSet(address indexed owner, ISwapGuard swapGuard);

    ComposableCoW composableCow;
    TWAP twap;
    GoodAfterTime gat;

    mapping(bytes32 => IConditionalOrder.ConditionalOrderParams) public leaves;

    function setUp() public virtual override(Base) {
        // setup Base
        super.setUp();

        // deploy composable cow
        composableCow = new ComposableCoW(address(settlement));

        // set safe1 to have the ComposableCoW `ISafeSignatureVerifier` custom verifier
        // we will set the domainSeparator to settlement.domainSeparator()
        safe1.execute(
            address(safe1),
            0,
            abi.encodeWithSelector(
                eHandler.setDomainVerifier.selector, settlement.domainSeparator(), address(composableCow)
            ),
            Enum.Operation.Call,
            signers()
        );

        // deploy order types
        twap = new TWAP();
        gat = new GoodAfterTime();
    }

    function test_SetUpState_ComposableCoWDomainVerifier_is_set() public {
        assertEq(address(eHandler.domainVerifiers(safe1, settlement.domainSeparator())), address(composableCow));
    }

    function test_SetUpState_ComposableCoWDomainSeparator_is_set() public {
        assertEq(composableCow.domainSeparator(), settlement.domainSeparator());
    }

    /**
     * @dev An end-to-end test of the ComposableCoW contract that tests the following:
     *      1. Does **NOT** validate a proof that is not authorized
     *      2. `owner` can set their merkle root
     *      3. Can lookup the merkle root for `owner`
     *      4. **DOES** validate a proof that is authorized
     *      5. `owner` can remove their merkle root
     *      6. Can lookup the merkle root for `owner` (should be 0)
     *      7. Does **NOT** validate a proof that is not authorized
     */
    function test_setRoot_e2e() public {
        IConditionalOrder.ConditionalOrderParams[] memory _leaves = getBundle(safe1, 50);
        (bytes32 root, bytes32[] memory proof, IConditionalOrder.ConditionalOrderParams memory params) =
            _leaves.getRootAndProof(0, leaves, getRoot, getProof);

        // The root stored in the contract should be 0
        assertEq(composableCow.roots(address(safe1)), bytes32(0));

        // Try and validate the proof (should fail as an invalid root is set)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // Set the root correctly - this should emit a `MerkleRootSet` event
        vm.expectEmit(true, true, true, true);
        ComposableCoW.Proof memory proofStruct = ComposableCoW.Proof({location: 0, data: ""});
        emit MerkleRootSet(address(safe1), root, proofStruct);
        setRoot(safe1, root, proofStruct);
        assertEq(composableCow.roots(address(safe1)), root);

        // Try and validate the proof (should pass as root is set)
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        uint256 snapshot = vm.snapshot(); // saves the state

        // Execute the order - this should pass as the order is valid
        settle(address(safe1), bob, order, signature, bytes4(0));

        vm.revertTo(snapshot); // restores the state

        // Remove the root
        vm.expectEmit(true, true, true, true);
        emit MerkleRootSet(address(safe1), bytes32(0), proofStruct);
        setRoot(safe1, bytes32(0), proofStruct);
        assertEq(composableCow.roots(address(safe1)), bytes32(0));

        // Try and validate the proof (should fail as root is removed)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
    }

    /**
     * @dev An end-to-end test of the ComposableCoW contract that tests the following:
     *     1. Does **NOT** validate a single order that is not authorized
     *     2. `owner` can create a single order
     *     3. Can lookup the validity of the single order for `owner`
     *     4. **DOES** validate a single order that is authorized
     */
    function test_createAndRemove_e2e() public {
        IConditionalOrder.ConditionalOrderParams memory params = getBundle(safe1, 1)[0];
        // by setting the proof to a zero-lenght bytes32 array, this indicates that the order
        // is to be processed as a single order
        bytes32[] memory proof = new bytes32[](0);

        bytes32 orderHash = keccak256(abi.encode(params));
        
        // first check to make sure that the order is not valid
        assertEq(composableCow.singleOrders(address(safe1), orderHash), false);

        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // now create the order
        vm.expectEmit(true, true, true, true);
        emit ConditionalOrderCreated(address(safe1), params);
        create(safe1, params, true);
        assertEq(composableCow.singleOrders(address(safe1), orderHash), true);

        uint256 snapshot = vm.snapshot(); // saves the state

        // This should work as the order is valid
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
        settle(address(safe1), bob, order, signature, bytes4(0));

        vm.revertTo(snapshot); // restores the state

        // now remove the order
        remove(safe1, orderHash);
        assertEq(composableCow.singleOrders(address(safe1), orderHash), false);

        // try and validate the order (should fail as the order is removed)
        settle(address(safe1), bob, order, signature, ComposableCoW.SingleOrderNotAuthed.selector);
    }

    /**
     * @dev An end-to-end test of the ComposableCoW contract that tests the following:
     *      1. Validates a single order with no swap guard
     *      2. `owner` can set a swap guard
     *      3. Swap guard does **NOT** allow an invalid order to be validated
     *      4. Swap guard allows the single order to be validated
     *      5. `owner` can remove the swap guard
     */
    function test_setSwapGuard_e2e() public {
        TestSwapGuard oddSwapGuard = new TestSwapGuard(1);
        TestSwapGuard evenSwapGuard = new TestSwapGuard(2);

        // Make sure that the swap guard is not set
        assertEq(address(composableCow.swapGuards(address(safe1))), address(0));

        IConditionalOrder.ConditionalOrderParams memory params = getBundle(safe1, 1)[0];
        // by setting the proof to a zero-length bytes32 array, this indicates that the order
        // is to be processed as a single order
        bytes32[] memory proof = new bytes32[](0);
        bytes32 orderHash = keccak256(abi.encode(params));

        create(safe1, params, true);
        assertEq(composableCow.singleOrders(address(safe1), orderHash), true);

        uint256 snapshot = vm.snapshot(); // saves the state

        // This should work as the order is valid
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
        settle(address(safe1), bob, order, signature, bytes4(0));

        vm.revertTo(snapshot); // restores the state

        // now set the swap guard
        vm.expectEmit(true, true, true, true);
        emit SwapGuardSet(address(safe1), evenSwapGuard);
        setSwapGuard(safe1, evenSwapGuard);

        // Now settlement should not work as the swap guard should not allow it
        settle(address(safe1), bob, order, signature, ComposableCoW.SwapGuardRestricted.selector);

        // Shouldn't be able to use `getTradeableOrderWithSignature` either
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // change to an odd swap guard
        vm.expectEmit(true, true, true, true);
        emit SwapGuardSet(address(safe1), oddSwapGuard);
        setSwapGuard(safe1, oddSwapGuard);

        // Now settlement should work as the swap guard should allow it
        settle(address(safe1), bob, order, signature, bytes4(0));

        // now remove the swap guard
        vm.expectEmit(true, true, true, true);
        emit SwapGuardSet(address(safe1), ISwapGuard(address(0)));
        setSwapGuard(safe1, ISwapGuard(address(0)));
    }

    function test_TWAP() public {
        // 1. Get the TWAP conditional orders that will be used to dogfood the ComposableCoW
        IConditionalOrder.ConditionalOrderParams[] memory _leaves = getBundle(safe1, 50);

        // 2. Do the merkle tree dance
        (bytes32 root, bytes32[] memory proof, IConditionalOrder.ConditionalOrderParams memory leaf) =
            _leaves.getRootAndProof(0, leaves, getRoot, getProof);

        // 3. Set the Merkle root
        setRoot(safe1, root, ComposableCoW.Proof({location: 0, data: ""}));

        // 4. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), leaf, bytes(""), proof);

        // 5. Execute the order
        settle(address(safe1), bob, order, signature, bytes4(0));
    }

    function setRoot(Safe safe, bytes32 root, ComposableCoW.Proof memory proof) private {
        safe.execute(
            address(composableCow),
            0,
            abi.encodeWithSelector(composableCow.setRoot.selector, root, proof),
            Enum.Operation.Call,
            signers()
        );
    }

    function setSwapGuard(Safe safe, ISwapGuard swapGuard) private {
        safe.execute(
            address(composableCow),
            0,
            abi.encodeWithSelector(composableCow.setSwapGuard.selector, swapGuard),
            Enum.Operation.Call,
            signers()
        );
    }

    function create(Safe safe, IConditionalOrder.ConditionalOrderParams memory params, bool dispatch) private {
        safe.execute(
            address(composableCow),
            0,
            abi.encodeWithSelector(composableCow.create.selector, params, dispatch),
            Enum.Operation.Call,
            signers()
        );
    }

    function remove(Safe safe, bytes32 orderHash) private {
        safe.execute(
            address(composableCow),
            0,
            abi.encodeWithSelector(composableCow.remove.selector, orderHash),
            Enum.Operation.Call,
            signers()
        );
    }

    function getBundle(Safe safe, uint256 size)
        private
        returns (IConditionalOrder.ConditionalOrderParams[] memory _leaves)
    {
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
        _leaves = new IConditionalOrder.ConditionalOrderParams[](size);
        for (uint256 i = 0; i < _leaves.length; i++) {
            _leaves[i] = IConditionalOrder.ConditionalOrderParams({
                handler: twap,
                salt: keccak256(abi.encode(bytes32(i))),
                staticInput: abi.encode(twapData)
            });
        }

        // 3. Set the ERC20 allowance for the bundle
        safe.execute(
            address(twapData.sellToken),
            0,
            abi.encodeWithSelector(IERC20.approve.selector, address(relayer), twapData.n * twapData.partSellAmount),
            Enum.Operation.Call,
            signers()
        );
    }
}

contract TestSwapGuard is BaseSwapGuard {
    uint256 private divisor;

    constructor(uint256 _divisor) {
        divisor = _divisor;
    }

    // only allow even amounts to be swapped
    function verify(
        GPv2Order.Data calldata order,
        IConditionalOrder.ConditionalOrderParams calldata,
        bytes calldata
    ) external view returns (bool) {
        return order.sellAmount % divisor == 0;
    }
}