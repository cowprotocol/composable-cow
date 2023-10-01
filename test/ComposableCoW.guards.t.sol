// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "./ComposableCoW.base.t.sol";

contract ComposableCoWGuardsTest is BaseComposableCoWTest {
    function setUp() public virtual override(BaseComposableCoWTest) {
        // setup Base
        super.setUp();
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
            composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);
        settle(address(safe1), bob, order, signature, hex"");

        // restores the state
        vm.revertTo(snapshot);

        // should set the swap guard
        _setSwapGuard(address(safe1), evenSwapGuard);

        // should not be able to settle as the swap guard doesn't allow it
        settle(
            address(safe1), bob, order, signature, abi.encodeWithSelector(ComposableCoW.SwapGuardRestricted.selector)
        );

        // should not be able to return the order as the swap guard doesn't allow it
        vm.expectRevert(ComposableCoW.SwapGuardRestricted.selector);
        composableCow.getTradeableOrderWithSignature(address(safe1), params, hex"", proof);

        // should set the swap guard to the odd swap guard
        _setSwapGuard(address(safe1), oddSwapGuard);

        // should be able to settle as the swap guard allows it
        settle(address(safe1), bob, order, signature, hex"");

        // can remove the swap guard
        _setSwapGuard(address(safe1), ISwapGuard(address(0)));
    }

    /// @dev `BaseSwapGuard` should support the appropriate interfaces
    function test_BaseSwapGuard_supportsInterface() public {
        ReceiverLock lock = new ReceiverLock();

        assertEq(lock.supportsInterface(type(ISwapGuard).interfaceId), true);
        assertEq(lock.supportsInterface(type(IERC165).interfaceId), true);
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
}
