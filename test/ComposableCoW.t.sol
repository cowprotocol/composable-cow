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
import {BaseConditionalOrder} from "../src/BaseConditionalOrder.sol";

import {TWAP, TWAPOrder} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {IConditionalOrder} from "../src/interfaces/IConditionalOrder.sol";
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

    function test_setRoot_FuzzSetAndEmit(address owner, bytes32 root) public {
        vm.assume(owner != address(0));
        vm.assume(root != bytes32(0));
        ComposableCoW.Proof memory proofStruct = ComposableCoW.Proof({location: 0, data: ""});
        assertTrue(composableCow.roots(owner) != root);

        _setRoot(owner, root, proofStruct);
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

        // try and validate the proof (should fail as an bytes32(0) root is set)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // sets the root correctly
        ComposableCoW.Proof memory proofStruct = ComposableCoW.Proof({location: 0, data: ""});
        _setRoot(address(safe1), root, proofStruct);

        // Trtryy and validate the proof (should pass as root is set)
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // save the state
        uint256 snapshot = vm.snapshot();

        // Execute the order - this should pass as the order is valid
        settle(address(safe1), bob, order, signature, bytes4(0));

        // restore the state
        vm.revertTo(snapshot);

        // removes the root correctly
        _setRoot(address(safe1), bytes32(0), proofStruct);

        // try and validate the proof (should fail as root is removed)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
    }

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

    function test_createAndRemove_FuzzSetAndEmit(address owner, address handler, bytes32 salt, bytes memory staticInput)
        public
    {
        vm.assume(owner != address(0));
        vm.assume(handler != address(0));
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });
        bytes32 orderHash = keccak256(abi.encode(params));

        assertEq(composableCow.singleOrders(owner, orderHash), false);

        // create the order
        _create(owner, params, true);

        // remove the order
        _remove(owner, params);

        assertEq(composableCow.singleOrders(owner, orderHash), false);
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
        _create(address(safe1), params, true);

        uint256 snapshot = vm.snapshot(); // saves the state

        // This should work as the order is valid
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
        settle(address(safe1), bob, order, signature, bytes4(0));

        vm.revertTo(snapshot); // restores the state

        // now remove the order
        _remove(address(safe1), params);

        // try and validate the order (should fail as the order is removed)
        settle(address(safe1), bob, order, signature, ComposableCoW.SingleOrderNotAuthed.selector);
    }

    function test_setSwapGuard_FuzzSetAndEmit(address owner, address swapGuard) public {
        vm.assume(owner != address(0));
        vm.assume(swapGuard != address(0));

        assertEq(address(composableCow.swapGuards(owner)), address(0));

        // set the swap guard
        _setSwapGuard(owner, ISwapGuard(swapGuard));

        // remove the swap guard
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
        TestSwapGuard oddSwapGuard = new TestSwapGuard(1);
        TestSwapGuard evenSwapGuard = new TestSwapGuard(2);

        // Make sure that the swap guard is not set
        assertEq(address(composableCow.swapGuards(address(safe1))), address(0));

        IConditionalOrder.ConditionalOrderParams memory params = getBundle(safe1, 1)[0];
        // by setting the proof to a zero-length bytes32 array, this indicates that the order
        // is to be processed as a single order
        bytes32[] memory proof = new bytes32[](0);

        _create(address(safe1), params, true);

        uint256 snapshot = vm.snapshot(); // saves the state

        // This should work as the order is valid
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);
        settle(address(safe1), bob, order, signature, bytes4(0));

        vm.revertTo(snapshot); // restores the state

        // now set the swap guard
        _setSwapGuard(address(safe1), evenSwapGuard);

        // Now settlement should not work as the swap guard should not allow it
        settle(address(safe1), bob, order, signature, ComposableCoW.SwapGuardRestricted.selector);

        // Shouldn't be able to use `getTradeableOrderWithSignature` either
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, bytes(""), proof);

        // change to an odd swap guard
        _setSwapGuard(address(safe1), oddSwapGuard);

        // Now settlement should work as the swap guard should allow it
        settle(address(safe1), bob, order, signature, bytes4(0));

        // now remove the swap guard
        _setSwapGuard(address(safe1), ISwapGuard(address(0)));
    }

    function test_isValidSafeSignature_RevertOnInvalidHash() public {
        // a test conditional order generator that will always return the order that we
        // give it in offchainInput.
        TestConditionalOrderGenerator generator = new TestConditionalOrderGenerator();

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(generator)),
            salt: keccak256("sssaaalllttt"),
            staticInput: bytes("")
        });

        _create(alice.addr, params, false);

        GPv2Order.Data memory order = getBlankOrder();
        GPv2Order.Data memory fraudulentOrder = getBlankOrder();
        fraudulentOrder.appData = keccak256("fraudulent order");

        bytes32 domainSeparator = composableCow.domainSeparator();

        // now try and validate the order
        vm.expectRevert(IConditionalOrder.OrderNotValid.selector);
        composableCow.isValidSafeSignature(
            Safe(payable(address(alice.addr))),
            address(0),
            GPv2Order.hash(order, domainSeparator),
            domainSeparator,
            bytes32(0),
            abi.encode(order),
            abi.encode(
                ComposableCoW.PayloadStruct({
                    proof: new bytes32[](0),
                    params: params,
                    offchainInput: abi.encode(fraudulentOrder)
                })
            )
        );
    }

    function test_isValidSafeSignature_FuzzRevertInvalidProof(
        address owner,
        bytes32[] memory proof,
        bytes32 root,
        address handler,
        bytes32 salt,
        bytes memory staticInput
    ) public {
        vm.assume(proof.length > 1);
        vm.assume(root != bytes32(0));
        vm.assume(handler != address(0));

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });

        _setRoot(owner, root, ComposableCoW.Proof({location: 0, data: ""}));

        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.isValidSafeSignature(
            Safe(payable(owner)),
            address(0), // sender isn't used
            keccak256("some gpv2order hash"),
            keccak256("some domain separator"),
            bytes32(0), // typeHash isn't used
            abi.encode(getBlankOrder()),
            abi.encode(ComposableCoW.PayloadStruct({proof: proof, params: params, offchainInput: bytes("")}))
        );
    }

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

    function test_isValidSafeSignature_FuzzPassesContextToHandler(address owner, bytes32 domainSeparator) public {
        vm.assume(owner != address(0));

        MirrorConditionalOrder mirror = new MirrorConditionalOrder();
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(mirror),
            salt: keccak256("mirror conditional order"),
            staticInput: bytes("")
        });

        _create(owner, params, false);

        GPv2Order.Data memory order = getBlankOrder();

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
                    ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: bytes("")})
                    )
            )
        );

        (bool success, bytes memory returnData) = address(composableCow).call(cd);

        assertTrue(!success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                IConditionalOrder.verify.selector,
                owner,
                address(0),
                keccak256(abi.encode(order)),
                domainSeparator,
                params.staticInput,
                bytes(""),
                order
            )
        );
    }

    function test_getTradeableOrderWithSignature_RevertInterfaceNotSupported() public {
        MirrorConditionalOrder mirror = new MirrorConditionalOrder();

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: mirror,
            salt: keccak256("mirror conditional order"),
            staticInput: bytes("")
        });

        _create(alice.addr, params, false);

        vm.expectRevert(ComposableCoW.InterfaceNotSupported.selector);
        composableCow.getTradeableOrderWithSignature(alice.addr, params, bytes(""), new bytes32[](0));
    }

    function test_getTradeableOrderWithSignature_FuzzRevertInvalidProof(
        address owner,
        bytes32[] memory proof,
        bytes32 root,
        address handler,
        bytes32 salt,
        bytes memory staticInput
    ) public {
        vm.assume(proof.length > 1);
        vm.assume(root != bytes32(0));
        vm.assume(handler != address(0));

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });

        _setRoot(owner, root, ComposableCoW.Proof({location: 0, data: ""}));

        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(owner, params, bytes(""), proof);
    }

    function test_getTradeableOrderWithSignature_FuzzRevertInvalidSingleOrder(
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

        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(owner, params, bytes(""), new bytes32[](0));
    }

    function test_getTradeableOrderWithSignature_ReturnsValidPayloadForSafe() public {
        TestConditionalOrderGenerator generator = new TestConditionalOrderGenerator();

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: generator,
            salt: keccak256("test conditional order"),
            staticInput: bytes("")
        });

        _create(address(safe1), params, false);

        // 1. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(getBlankOrder()), new bytes32[](0)
        );

        // 2. Check that the order is valid
        assertEq(
            ExtensibleFallbackHandler(address(safe1)).isValidSignature(
                GPv2Order.hash(order, composableCow.domainSeparator()), signature
            ),
            ERC1271.isValidSignature.selector
        );
    }

    function test_getTradeableOrderWithSignature_ReturnsValidPayloadForNonSafe() public {
        TestNonSafeWallet nonSafe = new TestNonSafeWallet(address(composableCow));
        TestConditionalOrderGenerator generator = new TestConditionalOrderGenerator();

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: generator,
            salt: keccak256("test conditional order"),
            staticInput: bytes("")
        });

        _create(address(nonSafe), params, false);

        // 1. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(nonSafe), params, abi.encode(getBlankOrder()), new bytes32[](0)
        );

        // 2. Check that the order is valid
        assertEq(
            nonSafe.isValidSignature(GPv2Order.hash(order, composableCow.domainSeparator()), signature),
            ERC1271.isValidSignature.selector
        );
    }

    function test_ERC1271Forwarder_isValidSignature_RevertsOnFraudulentHash() public {
        TestNonSafeWallet nonSafe = new TestNonSafeWallet(address(composableCow));
        TestConditionalOrderGenerator generator = new TestConditionalOrderGenerator();

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: generator,
            salt: keccak256("test conditional order"),
            staticInput: bytes("")
        });

        _create(address(nonSafe), params, false);

        // 1. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(nonSafe), params, abi.encode(getBlankOrder()), new bytes32[](0)
        );

        // 2. Generate an incorrectly signed digest
        bytes32 badDigest = GPv2Order.hash(order, keccak256("deadbeef"));

        // 3. Submit with mismatched digest and signature
        vm.expectRevert("ERC1271Forwarder: invalid hash");
        nonSafe.isValidSignature(badDigest, signature);
    }

    function test_ReceiverLock_verify_RevertsWhenReceiverNotSelf() public {
        TestConditionalOrderGenerator generator = new TestConditionalOrderGenerator();
        ReceiverLock lock = new ReceiverLock();

        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: generator,
            salt: keccak256("test conditional order"),
            staticInput: bytes("")
        });

        _create(address(safe1), params, false);

        GPv2Order.Data memory orderOtherReceiver = getBlankOrder();
        orderOtherReceiver.receiver = address(0xdeadbeef);
        bytes32 domainSeparator = composableCow.domainSeparator();

        // 1. Get the order and signature
        (GPv2Order.Data memory order, bytes memory signature) = composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(orderOtherReceiver), new bytes32[](0)
        );

        // 2. Set the guard
        _setSwapGuard(address(safe1), lock);

        // 3. `getTradeableOrderWithSignature` should revert
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        composableCow.getTradeableOrderWithSignature(
            address(safe1), params, abi.encode(orderOtherReceiver), new bytes32[](0)
        );

        // 4. `isValidSignature` should revert
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        ExtensibleFallbackHandler(address(safe1)).isValidSignature(GPv2Order.hash(order, domainSeparator), signature);
    }

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

    function _setRoot(address owner, bytes32 root, ComposableCoW.Proof memory proof) internal {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MerkleRootSet(owner, root, proof);
        composableCow.setRoot(root, proof);
        assertEq(composableCow.roots(owner), root);
    }

    function _setSwapGuard(address owner, ISwapGuard guard) internal {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SwapGuardSet(owner, guard);
        composableCow.setSwapGuard(guard);
        assertEq(address(composableCow.swapGuards(owner)), address(guard));
    }

    function _create(address owner, IConditionalOrder.ConditionalOrderParams memory params, bool dispatch) internal {
        vm.prank(owner);
        if (dispatch) {
            vm.expectEmit(true, true, true, true);
            emit ConditionalOrderCreated(owner, params);
        }
        composableCow.create(params, dispatch);
        assertEq(composableCow.singleOrders(owner, keccak256(abi.encode(params))), true);
    }

    function _remove(address owner, IConditionalOrder.ConditionalOrderParams memory params) internal {
        vm.prank(owner);
        bytes32 orderHash = keccak256(abi.encode(params));
        composableCow.remove(orderHash);
        assertEq(composableCow.singleOrders(owner, orderHash), false);
    }

    function getBlankOrder() private pure returns (GPv2Order.Data memory order) {
        order = GPv2Order.Data({
            sellToken: IERC20(address(0)),
            buyToken: IERC20(address(0)),
            receiver: address(0),
            sellAmount: 0,
            buyAmount: 0,
            validTo: 0,
            appData: keccak256("random appdata"),
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
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

contract TestNonSafeWallet is ERC1271Forwarder {
    constructor(address composableCow) ERC1271Forwarder(ComposableCoW(composableCow)) {}
}

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
