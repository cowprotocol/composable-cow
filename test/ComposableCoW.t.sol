// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import {IERC20, IERC20Metadata} from "@openzeppelin/interfaces/IERC20Metadata.sol";
import {Merkle} from "murky/Merkle.sol";

import "safe/Safe.sol";

// Testing Libraries
import {Base} from "./Base.t.sol";
import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";
import {SafeLib} from "./libraries/SafeLib.t.sol";
import {ComposableCoWLib} from "./libraries/ComposableCoWLib.t.sol";

import {BaseConditionalOrder} from "../src/BaseConditionalOrder.sol";
import {BaseSwapGuard} from "../src/guards/BaseSwapGuard.sol";

import {TWAP, TWAPOrder} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {ERC1271Forwarder} from "../src/ERC1271Forwarder.sol";
import {ReceiverLock} from "../src/guards/ReceiverLock.sol";

import "../src/ComposableCoW.sol";

contract ComposableCoWTest is Base, Merkle {
    using TestAccountLib for TestAccount[];
    using TestAccountLib for TestAccount;
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams;
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];
    using SafeLib for Safe;

    event MerkleRootSet(address indexed owner, bytes32 root, ComposableCoW.Proof proof);
    event ConditionalOrderCreated(address indexed owner, IConditionalOrder.ConditionalOrderParams params);
    event SwapGuardSet(address indexed owner, ISwapGuard swapGuard);

    ComposableCoW composableCow;
    TWAP twap;
    GoodAfterTime gat;

    TestConditionalOrderGenerator passThrough;
    MirrorConditionalOrder mirror;

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

        // deploy conditional order handlers (types)
        twap = new TWAP();
        gat = new GoodAfterTime();
        passThrough = new TestConditionalOrderGenerator();
        mirror = new MirrorConditionalOrder();
    }

    /// @dev Ensure `ComposableCoW` contract is the `ISafeSignatureVerifier` for `safe1` on the `settlement` domain
    function test_SetUpState_ComposableCoWDomainVerifier_is_set() public {
        assertEq(address(eHandler.domainVerifiers(safe1, settlement.domainSeparator())), address(composableCow));
    }

    /// @dev Ensure `ComposableCoW` and `Settlement` have the same domain separator
    function test_SetUpState_ComposableCoWDomainSeparator_is_set() public {
        assertEq(composableCow.domainSeparator(), settlement.domainSeparator());
    }

    /// @dev Can set the Merkle root for `owner`
    function test_setRoot_FuzzSetAndEmit(address owner, bytes32 root) public {
        _setRoot(owner, root, ComposableCoW.Proof({location: 0, data: ""}));
    }

    /**
     * @dev An end-to-end test of the ComposableCoW contract that tests the following:
     *      1. Does **NOT** validate a proof that is not authorized
     *      2. `owner` can set their merkle root
     *      3. **DOES** validate a proof that is authorized
     *      4. `owner` can remove their merkle root
     *      5. Does **NOT** validate a proof that is not authorized
     */
    function test_setRoot_e2e() public {
        IConditionalOrder.ConditionalOrderParams[] memory _leaves = getBundle(safe1, 50);
        (bytes32 root, bytes32[] memory proof, IConditionalOrder.ConditionalOrderParams memory params) =
            _leaves.getRootAndProof(0, leaves, getRoot, getProof);

        // should fail to validate the proof as root is still set bytes32(0)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // should set the root correctly
        ComposableCoW.Proof memory proofStruct = ComposableCoW.Proof({location: 0, data: ""});
        _setRoot(address(safe1), root, proofStruct);

        // should pass with the root correctly set
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // save the state
        uint256 snapshot = vm.snapshot();

        // should successfully execute the order
        settle(address(safe1), bob, order, signature, bytes4(0));

        // restore the state
        vm.revertTo(snapshot);

        // should revoke the root
        _setRoot(address(safe1), bytes32(0), proofStruct);

        // should fail as the root is set to bytes32(0)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
    }

    /// @dev Should disallow setting a handler that is address(0)
    function test_create_RevertOnInvalidHandler() public {
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(0)),
            salt: keccak256("zero is invalid handler"),
            staticInput: ""
        });

        vm.expectRevert(ComposableCoW.InvalidHandler.selector);

        // should revert as the handler (address(0)) is invalid
        composableCow.create(params, true);
    }

    /// @dev should be able to create and remove a single order
    function test_createAndRemove_FuzzSetAndEmit(address owner, address handler, bytes32 salt, bytes memory staticInput)
        public
    {
        // address(0) is not a valid handler
        vm.assume(handler != address(0));

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });
        bytes32 orderHash = keccak256(abi.encode(params));

        // order should not exist
        assertEq(composableCow.singleOrders(owner, orderHash), false);

        // create the order
        _create(owner, params, true);

        // remove the order
        _remove(owner, params);
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
        // by setting the proof to a zero-length bytes32 array, this indicates that the order
        // is to be processed as a single order
        bytes32[] memory proof = new bytes32[](0);
        bytes32 orderHash = keccak256(abi.encode(params));

        // order should not exist
        assertEq(composableCow.singleOrders(address(safe1), orderHash), false);

        // should fail to return the order as it is not authorized
        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // can create the order
        _create(address(safe1), params, true);

        // save the state
        uint256 snapshot = vm.snapshot();

        // order can be returned as it is authorized
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // should successfully settle the order
        settle(address(safe1), bob, order, signature, bytes4(0));

        // restores the state
        vm.revertTo(snapshot);

        // can remove the order
        _remove(address(safe1), params);

        // should fail to settle the order as it has been removed
        settle(address(safe1), bob, order, signature, ComposableCoW.SingleOrderNotAuthed.selector);
    }

    /// @dev Can set and remove a swap guard
    function test_setSwapGuard_FuzzSetAndEmit(address owner, address swapGuard) public {
        // address(0) is the no-op swap guard
        vm.assume(swapGuard != address(0));

        // swap guard should not be set by default
        assertEq(address(composableCow.swapGuards(owner)), address(0));

        // should set the swap guard
        _setSwapGuard(owner, ISwapGuard(swapGuard));

        // should remove the swap guard
        _setSwapGuard(owner, ISwapGuard(address(0)));
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
        // create a swap guard that only allows odd orders
        TestSwapGuard oddSwapGuard = new TestSwapGuard(1);
        // create a swap guard that only allows even orders
        TestSwapGuard evenSwapGuard = new TestSwapGuard(2);

        // should not have a swap guard set by default
        assertEq(address(composableCow.swapGuards(address(safe1))), address(0));

        IConditionalOrder.ConditionalOrderParams memory params = getBundle(safe1, 1)[0];
        // zero-length bytes32 array indicates a single order
        bytes32[] memory proof = new bytes32[](0);

        // should create the order
        _create(address(safe1), params, true);

        // saves the state
        uint256 snapshot = vm.snapshot();

        // should work as there is no swap guard set
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
        settle(address(safe1), bob, order, signature, bytes4(0));

        // restores the state
        vm.revertTo(snapshot);

        // should set the swap guard
        _setSwapGuard(address(safe1), evenSwapGuard);

        // should not be able to settle as the swap guard doesn't allow it
        settle(address(safe1), bob, order, signature, ComposableCoW.SwapGuardRestricted.selector);

        // should not be able to return the order as the swap guard doesn't allow it
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // should set the swap guard to the odd swap guard
        _setSwapGuard(address(safe1), oddSwapGuard);

        // should be able to settle as the swap guard allows it
        settle(address(safe1), bob, order, signature, bytes4(0));

        // can remove the swap guard
        _setSwapGuard(address(safe1), ISwapGuard(address(0)));
    }

    /// @dev `BaseConditionalOrder` enforces that the order hash is valid
    function test_isValidSafeSignature_BaseConditionalOrder_RevertOnInvalidHash() public {
        IConditionalOrder.ConditionalOrderParams memory params = getPassthroughOrder();

        // should create the order
        _create(alice.addr, params, false);

        // create a real and fake order
        GPv2Order.Data memory order1 = getBlankOrder();
        GPv2Order.Data memory order2 = getOrderWithAppData(keccak256("order2"));

        // cache the domain separator as vm.expectRevert will not function if the
        // domain separator is called within the `isValidSafeSignature` function call.
        bytes32 domainSeparator = composableCow.domainSeparator();

        // should revert as the order hash mismatches
        vm.expectRevert(IConditionalOrder.OrderNotValid.selector);
        composableCow.isValidSafeSignature(
            Safe(payable(address(alice.addr))),
            address(0),
            GPv2Order.hash(order1, domainSeparator),
            domainSeparator,
            bytes32(0),
            abi.encode(order1),
            abi.encode(
                ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: abi.encode(order2)})
            )
        );
    }

    /// @dev Reverts on an invalid proof
    function test_isValidSafeSignature_FuzzRevertInvalidProof(
        address owner,
        bytes32[] memory proof,
        bytes32 root,
        address handler,
        bytes32 salt,
        bytes memory staticInput
    ) public {
        // proof.length > 0 is used to indicate a merkle proof
        vm.assume(proof.length > 0);

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });

        // should set the root
        _setRoot(owner, root, ComposableCoW.Proof({location: 0, data: ""}));

        // should revert as the proof is invalid
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.isValidSafeSignature(
            Safe(payable(owner)),
            address(0), // sender isn't used
            keccak256("some GPv2Order hash"),
            keccak256("some domain separator"),
            bytes32(0), // typeHash isn't used
            abi.encode(getBlankOrder()),
            abi.encode(ComposableCoW.PayloadStruct({proof: proof, params: params, offchainInput: bytes("")}))
        );
    }

    /// @dev Reverts on an invalid single order
    function test_isValidSafeSignature_FuzzRevertInvalidSingleOrder(
        address owner,
        address handler,
        bytes32 salt,
        bytes memory staticInput
    ) public {
        vm.assume(handler != address(0));

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });

        // should revert as the order has not been created
        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        composableCow.isValidSafeSignature(
            Safe(payable(owner)),
            address(0), // sender isn't used
            keccak256("some gpv2order hash"),
            keccak256("some domain separator"),
            bytes32(0), // typeHash isn't used
            abi.encode(getBlankOrder()),
            abi.encode(ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: bytes("")}))
        );
    }

    /// @dev Make sure `isValidSafeSignature` passes the context to the handler
    function test_isValidSafeSignature_FuzzPassesContextToHandler(address owner, bytes32 domainSeparator) public {
        // Use the mirror handler as we can use it to inspect the calldata
        // passed to the handler.
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(mirror),
            salt: keccak256("mirror"),
            staticInput: bytes("")
        });

        // should create a single order
        _create(owner, params, false);

        // get a blank order
        GPv2Order.Data memory order = getBlankOrder();
        bytes memory offchainInput = bytes("");

        // As we want to inspect the revert data, we need to do a low-level call.
        bytes memory cd = abi.encodeCall(
            composableCow.isValidSafeSignature,
            (
                Safe(payable(address(owner))),
                address(0), // sender isn't used
                keccak256(abi.encode(order)),
                domainSeparator,
                bytes32(0), // typeHash isn't used
                abi.encode(order),
                abi.encode(
                    ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: offchainInput})
                    )
            )
        );

        (bool success, bytes memory returnData) = address(composableCow).call(cd);

        // should revert as the mirror handler will always revert
        assertTrue(!success);

        // the return data should equal the call data to the handler's `verify` function
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IConditionalOrder.verify.selector,
                owner,
                address(0), // sender isn't used
                keccak256(abi.encode(order)),
                domainSeparator,
                params.staticInput,
                offchainInput,
                order
            )
        );
    }

    /// @dev `getTradeableOrderWithSignature` should revert if the interface is not supported
    function test_getTradeableOrderWithSignature_RevertInterfaceNotSupported() public {
        // use the mirror handler as it does not support the interface
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: mirror,
            salt: keccak256("mirror"),
            staticInput: bytes("")
        });

        // should create a single order
        _create(alice.addr, params, false);

        // should revert as the interface is not supported
        vm.expectRevert(ComposableCoW.InterfaceNotSupported.selector);
        composableCow.getTradeableOrderWithSignature(alice.addr, params, bytes(""), new bytes32[](0));
    }

    /// @dev `getTradeableOrderWithSignature` should revert if given an invalid proof
    function test_getTradeableOrderWithSignature_FuzzRevertInvalidProof(
        address owner,
        bytes32[] memory proof,
        bytes32 root,
        address handler,
        bytes32 salt,
        bytes memory staticInput
    ) public {
        // proof.length > 0 is used to indicate a merkle proof
        vm.assume(proof.length > 0);

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });

        // should set the root
        _setRoot(owner, root, ComposableCoW.Proof({location: 0, data: ""}));

        // should revert as the proof is invalid
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(owner, params, bytes(""), proof);
    }

    /// @dev `getTradeableOrderWithSignature` should revert if given an invalid single order
    function test_getTradeableOrderWithSignature_FuzzRevertInvalidSingleOrder(
        address owner,
        address handler,
        bytes32 salt,
        bytes memory staticInput
    ) public {
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });

        // should revert as the order has not been created
        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(owner, params, bytes(""), new bytes32[](0));
    }

    /// @dev should return a valid payload for a safe
    function test_getTradeableOrderWithSignature_ReturnsValidPayloadForSafe() public {
        // use the pass through handler as it extends `BaseConditionalOrder` which supports the interface
        IConditionalOrder.ConditionalOrderParams memory params = getPassthroughOrder();

        // should create a single order
        _create(address(safe1), params, false);

        // should return a valid order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(getBlankOrder()), new bytes32[](0)
        );

        // order should be valid by using the `isValidSignature` function on the safe
        assertEq(
            ExtensibleFallbackHandler(address(safe1)).isValidSignature(
                GPv2Order.hash(order, composableCow.domainSeparator()), signature
            ),
            ERC1271.isValidSignature.selector
        );
    }

    /// @dev should return a valid payload for a non-safe (ERC1271Forwarder)
    function test_getTradeableOrderWithSignature_ReturnsValidPayloadForNonSafe() public {
        // Create a non-safe wallet, which is an ERC1271Forwarder
        TestNonSafeWallet nonSafe = new TestNonSafeWallet(address(composableCow));
        IConditionalOrder.ConditionalOrderParams memory params = getPassthroughOrder();

        // should create a single order
        _create(address(nonSafe), params, false);

        // should return a valid order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(nonSafe), params, abi.encode(getBlankOrder()), new bytes32[](0)
        );

        // order should be valid by using the `isValidSignature` function on the non-safe
        assertEq(
            nonSafe.isValidSignature(GPv2Order.hash(order, composableCow.domainSeparator()), signature),
            ERC1271.isValidSignature.selector
        );
    }

    /// @dev `ERC1271Forwarder` should revert on hash mismatch
    function test_ERC1271Forwarder_isValidSignature_RevertsOnBadHash() public {
        TestNonSafeWallet nonSafe = new TestNonSafeWallet(address(composableCow));
        IConditionalOrder.ConditionalOrderParams memory params = getPassthroughOrder();

        // should create a single order
        _create(address(nonSafe), params, false);

        // should return a valid order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(nonSafe), params, abi.encode(getBlankOrder()), new bytes32[](0)
        );

        bytes32 badDigest = GPv2Order.hash(order, keccak256("deadbeef"));

        // should revert when substituting the hash with a bad one
        vm.expectRevert("ERC1271Forwarder: invalid hash");
        nonSafe.isValidSignature(badDigest, signature);
    }

    /// @dev `ReceiverLock` should revert if the receiver is not the safe
    function test_ReceiverLock_verify_FuzzRevertsWhenReceiverNotSelf(address receiver) public {
        // address(0) is used to indicate self as the receiver, so we can't use it here
        vm.assume(receiver != address(0));

        ReceiverLock lock = new ReceiverLock();
        IConditionalOrder.ConditionalOrderParams memory params = getPassthroughOrder();

        // should create a single order
        _create(address(safe1), params, false);

        // create a blank order with a different receiver
        GPv2Order.Data memory orderOtherReceiver = getBlankOrder();
        orderOtherReceiver.receiver = receiver;

        // cache the domain separator
        bytes32 domainSeparator = composableCow.domainSeparator();

        // should return a valid order and signature (no guard is set)
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(orderOtherReceiver), new bytes32[](0)
        );

        // should set the swap guard
        _setSwapGuard(address(safe1), lock);

        // should revert as the receiver is not the safe
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(orderOtherReceiver), new bytes32[](0)
        );

        // should revert as the receiver is not the safe
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        ExtensibleFallbackHandler(address(safe1)).isValidSignature(GPv2Order.hash(order, domainSeparator), signature);
    }

    /// @dev `BaseSwapGuard` should support the appropriate interfaces
    function test_BaseSwapGuard_supportsInterface() public {
        ReceiverLock lock = new ReceiverLock();

        assertEq(lock.supportsInterface(type(ISwapGuard).interfaceId), true);
        assertEq(lock.supportsInterface(type(IERC165).interfaceId), true);
    }

    function test_TWAP() public {
        // 1. Get the TWAP conditional orders that will be used to dogfood the ComposableCoW
        IConditionalOrder.ConditionalOrderParams[] memory _leaves = getBundle(safe1, 50);

        // 2. Do the merkle tree dance
        (bytes32 root, bytes32[] memory proof, IConditionalOrder.ConditionalOrderParams memory leaf) =
            _leaves.getRootAndProof(0, leaves, getRoot, getProof);

        _setRoot(address(safe1), root, ComposableCoW.Proof({location: 0, data: ""}));

        // 4. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), leaf, bytes(""), proof);

        // 5. Execute the order
        settle(address(safe1), bob, order, signature, bytes4(0));
    }

    // --- Helpers ---

    /// @dev Sets the root and checks events / state
    function _setRoot(address owner, bytes32 root, ComposableCoW.Proof memory proof) internal {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MerkleRootSet(owner, root, proof);
        composableCow.setRoot(root, proof);
        assertEq(composableCow.roots(owner), root);
    }

    /// @dev Sets the swap guard and checks events / state
    function _setSwapGuard(address owner, ISwapGuard guard) internal {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SwapGuardSet(owner, guard);
        composableCow.setSwapGuard(guard);
        assertEq(address(composableCow.swapGuards(owner)), address(guard));
    }

    /// @dev Creates a single order and checks events / state
    function _create(address owner, IConditionalOrder.ConditionalOrderParams memory params, bool dispatch) internal {
        vm.prank(owner);
        if (dispatch) {
            vm.expectEmit(true, true, true, true);
            emit ConditionalOrderCreated(owner, params);
        }
        composableCow.create(params, dispatch);
        assertEq(composableCow.singleOrders(owner, keccak256(abi.encode(params))), true);
    }

    /// @dev Removes a single order and checks state
    function _remove(address owner, IConditionalOrder.ConditionalOrderParams memory params) internal {
        vm.prank(owner);
        bytes32 orderHash = keccak256(abi.encode(params));
        composableCow.remove(orderHash);
        assertEq(composableCow.singleOrders(owner, orderHash), false);
    }

    function getBlankOrder() private pure returns (GPv2Order.Data memory order) {
        return getOrderWithAppData(keccak256("blank order"));
    }

    function getOrderWithAppData(bytes32 appData) private pure returns (GPv2Order.Data memory order) {
        order = GPv2Order.Data({
            sellToken: IERC20(address(0)),
            buyToken: IERC20(address(0)),
            receiver: address(0),
            sellAmount: 0,
            buyAmount: 0,
            validTo: 0,
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function getPassthroughOrder() private view returns (IConditionalOrder.ConditionalOrderParams memory) {
        return IConditionalOrder.ConditionalOrderParams({
            handler: passThrough,
            salt: keccak256("pass through order"),
            staticInput: bytes("")
        });
    }

    function getBundle(Safe safe, uint256 n)
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

        // 2. Create n conditional orders as leaves of the ComposableCoW
        _leaves = new IConditionalOrder.ConditionalOrderParams[](n);
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

/// @dev A test swap guard that only allows amounts that are divisible by a given divisor
contract TestSwapGuard is BaseSwapGuard {
    uint256 private divisor;

    constructor(uint256 _divisor) {
        divisor = _divisor;
    }

    // only allow even amounts to be swapped
    function verify(GPv2Order.Data calldata order, IConditionalOrder.ConditionalOrderParams calldata, bytes calldata)
        external
        view
        returns (bool)
    {
        return order.sellAmount % divisor == 0;
    }
}

/// @dev A conditional order handler used for testing that returns the GPv2Order passed in as `offchainInput`
contract TestConditionalOrderGenerator is BaseConditionalOrder {
    function getTradeableOrder(address, address, bytes calldata, bytes calldata offchainInput)
        public
        pure
        override
        returns (GPv2Order.Data memory order)
    {
        order = abi.decode(offchainInput, (GPv2Order.Data));
    }
}

/// @dev Stub ERC1271Forwarder that forwards to a ComposableCoW
contract TestNonSafeWallet is ERC1271Forwarder {
    constructor(address composableCow) ERC1271Forwarder(ComposableCoW(composableCow)) {}
}

/// @dev A conditional order handler used for testing that reverts on verify
contract MirrorConditionalOrder is IConditionalOrder {
    function verify(address, address, bytes32, bytes32, bytes calldata, bytes calldata, GPv2Order.Data calldata)
        external
        pure
        override
    {
        // use assembly to set the return data to calldata
        assembly {
            calldatacopy(0, 0, calldatasize())
            revert(0, calldatasize())
        }
    }
}
