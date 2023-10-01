// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "./ComposableCoW.base.t.sol";

contract ComposableCoWTest is BaseComposableCoWTest {
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams[];

    function setUp() public virtual override(BaseComposableCoWTest) {
        // setup Base
        super.setUp();
    }

    /// @dev Can set the Merkle root for `owner`
    function test_setRoot_FuzzSetAndEmit(address owner, bytes32 root) public {
        _setRoot(owner, root, emptyProof());
    }

    function test_setRootWithContext_FuzzSetAndEmit(address owner, bytes32 root, bytes32 data) public {
        _setRootWithContext(owner, root, emptyProof(), testContextValue, abi.encode(data));
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
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // should set the root correctly
        ComposableCoW.Proof memory proofStruct = emptyProof();
        _setRoot(address(safe1), root, proofStruct);

        // should pass with the root correctly set
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // save the state
        uint256 snapshot = vm.snapshot();

        // should successfully execute the order
        settle(address(safe1), bob, order, signature, hex"");

        // restore the state
        vm.revertTo(snapshot);

        // should revoke the root
        _setRoot(address(safe1), bytes32(0), proofStruct);

        // should fail as the root is set to bytes32(0)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);
    }

    /**
     * @dev An end-to-end test of the ComposableCoW contract that tests the following:
     *      1. Does **NOT** validate a proof that is not authorized
     *      2. `owner` can set their merkle root
     *      3. **DOES** validate a proof that is authorized
     *      4. `owner` can remove their merkle root
     *      5. Does **NOT** validate a proof that is not authorized
     */
    function test_setRootWithContext_e2e() public {
        IConditionalOrder.ConditionalOrderParams[] memory _leaves = getBundle(safe1, 50);
        (bytes32 root, bytes32[] memory proof, IConditionalOrder.ConditionalOrderParams memory params) =
            _leaves.getRootAndProof(0, leaves, getRoot, getProof);

        // should fail to validate the proof as root is still set bytes32(0)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // should set the root correctly
        ComposableCoW.Proof memory proofStruct = emptyProof();
        _setRootWithContext(address(safe1), root, proofStruct, testContextValue, abi.encode(bytes32("testValue")));

        // should pass with the root correctly set
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // save the state
        uint256 snapshot = vm.snapshot();

        // should successfully execute the order
        settle(address(safe1), bob, order, signature, hex"");

        // restore the state
        vm.revertTo(snapshot);

        // should revoke the root
        _setRoot(address(safe1), bytes32(0), proofStruct);

        // should fail as the root is set to bytes32(0)
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);
    }

    /// @dev Should disallow setting a handler that is address(0)
    function test_create_RevertOnInvalidHandler() public {
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(address(0)),
            salt: keccak256("zero is invalid handler"),
            staticInput: hex""
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

    /// @dev should be able to create and remove a single order
    function test_createWithContextAndRemove_FuzzSetAndEmit(
        address owner,
        address handler,
        bytes32 salt,
        bytes memory staticInput,
        bytes32 ctxValue
    ) public {
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
        _createWithContext(owner, params, testContextValue, abi.encode(ctxValue), true);

        // cabinet should have the correct value at the context location
        assertEq(composableCow.cabinet(owner, orderHash), ctxValue);

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
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // can create the order
        _create(address(safe1), params, true);

        // save the state
        uint256 snapshot = vm.snapshot();

        // order can be returned as it is authorized
        (GPv2Order.Data memory order, bytes memory signature) =
            composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // should successfully settle the order
        settle(address(safe1), bob, order, signature, hex"");

        // restores the state
        vm.revertTo(snapshot);

        // can remove the order
        _remove(address(safe1), params);

        // should fail to settle the order as it has been removed
        settle(
            address(safe1), bob, order, signature, abi.encodeWithSelector(ComposableCoW.SingleOrderNotAuthed.selector)
        );
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
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, INVALID_HASH));
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
        _setRoot(owner, root, emptyProof());

        // should revert as the proof is invalid
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.isValidSafeSignature(
            Safe(payable(owner)),
            address(0), // sender isn't used
            keccak256("some GPv2Order hash"),
            keccak256("some domain separator"),
            bytes32(0), // typeHash isn't used
            abi.encode(getBlankOrder()),
            abi.encode(ComposableCoW.PayloadStruct({proof: proof, params: params, offchainInput: hex""}))
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
            abi.encode(ComposableCoW.PayloadStruct({proof: new bytes32[](0), params: params, offchainInput: hex""}))
        );
    }

    /// @dev Make sure `isValidSafeSignature` passes the context to the handler
    function test_isValidSafeSignature_FuzzPassesContextToHandler(address owner, bytes32 domainSeparator) public {
        // Use the mirror handler as we can use it to inspect the calldata
        // passed to the handler.
        IConditionalOrder.ConditionalOrderParams memory params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(mirror),
            salt: keccak256("mirror"),
            staticInput: hex""
        });

        // should create a single order
        _create(owner, params, false);

        // get a blank order
        GPv2Order.Data memory order = getBlankOrder();
        bytes memory offchainInput = hex"";

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
                keccak256(abi.encode(params)), // as a single order, ctx is H(params)
                params.staticInput,
                offchainInput,
                order
            )
        );
    }

    /// @dev `getTradeableOrderWithSignature` should revert if the interface is not supported
    function test_getTradeableOrderWithSignature_RevertInterfaceNotSupported() public {
        // use the mirror handler as it does not support the interface
        IConditionalOrder.ConditionalOrderParams memory params =
            IConditionalOrder.ConditionalOrderParams({handler: mirror, salt: keccak256("mirror"), staticInput: hex""});

        // should create a single order
        _create(alice.addr, params, false);

        // should revert as the interface is not supported
        vm.expectRevert(ComposableCoW.InterfaceNotSupported.selector);
        composableCow.getTradeableOrderWithSignature(alice.addr, params, hex"", new bytes32[](0));
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
        _setRoot(owner, root, emptyProof());

        // should revert as the proof is invalid
        vm.expectRevert(ComposableCoW.ProofNotAuthed.selector);
        composableCow.getTradeableOrderWithSignature(owner, params, hex"", proof);
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
        composableCow.getTradeableOrderWithSignature(owner, params, hex"", new bytes32[](0));
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
}
