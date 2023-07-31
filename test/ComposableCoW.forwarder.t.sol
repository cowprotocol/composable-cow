// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "./ComposableCoW.base.t.sol";

contract ComposableCoWForwarderTest is BaseComposableCoWTest {
    function setUp() public virtual override(BaseComposableCoWTest) {
        // setup Base
        super.setUp();
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
        vm.expectRevert(ERC1271Forwarder.InvalidHash.selector);
        nonSafe.isValidSignature(badDigest, signature);
    }
}
