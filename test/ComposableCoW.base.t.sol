// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Merkle} from "murky/Merkle.sol";

import "safe/Safe.sol";

// Testing Libraries
import {Base} from "./Base.t.sol";
import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";
import {SafeLib} from "./libraries/SafeLib.t.sol";
import {ComposableCoWLib} from "./libraries/ComposableCoWLib.t.sol";

import "../src/BaseConditionalOrder.sol";
import {BaseSwapGuard} from "../src/guards/BaseSwapGuard.sol";

import {TWAP, TWAPOrder} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {ERC1271Forwarder} from "../src/ERC1271Forwarder.sol";
import {ReceiverLock} from "../src/guards/ReceiverLock.sol";

import {IValueFactory} from "../src/interfaces/IValueFactory.sol";

import "../src/ComposableCoW.sol";

contract BaseComposableCoWTest is Base, Merkle {
    using ComposableCoWLib for IConditionalOrder.ConditionalOrderParams;
    using SafeLib for Safe;

    event MerkleRootSet(address indexed owner, bytes32 root, ComposableCoW.Proof proof);
    event ConditionalOrderCreated(address indexed owner, IConditionalOrder.ConditionalOrderParams params);
    event SwapGuardSet(address indexed owner, ISwapGuard swapGuard);

    ComposableCoW composableCow;

    TestConditionalOrderGenerator passThrough;
    TestContextSpecifyValue testContextValue;
    MirrorConditionalOrder mirror;
    TWAP twap;

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

        // deploy test context specify value
        testContextValue = new TestContextSpecifyValue();

        // deploy conditional order handlers (types)
        passThrough = new TestConditionalOrderGenerator();
        mirror = new MirrorConditionalOrder();

        twap = new TWAP(composableCow);
    }

    /// @dev Ensure `ComposableCoW` contract is the `ISafeSignatureVerifier` for `safe1` on the `settlement` domain
    function test_SetUpState_ComposableCoWDomainVerifier_is_set() public {
        assertEq(address(eHandler.domainVerifiers(safe1, settlement.domainSeparator())), address(composableCow));
    }

    /// @dev Ensure `ComposableCoW` and `Settlement` have the same domain separator
    function test_SetUpState_ComposableCoWDomainSeparator_is_set() public {
        assertEq(composableCow.domainSeparator(), settlement.domainSeparator());
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

    /// @dev Sets the root with context and checks events / state
    function _setRootWithContext(
        address owner,
        bytes32 root,
        ComposableCoW.Proof memory proof,
        IValueFactory valueFactory,
        bytes memory data
    ) internal {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit MerkleRootSet(owner, root, proof);
        composableCow.setRootWithContext(root, proof, valueFactory, data);
        assertEq(composableCow.roots(owner), root);
        assertEq(composableCow.cabinet(owner, bytes32(0)), abi.decode(data, (bytes32)));
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

    /// @dev Creates a single order with context and checks events / state
    function _createWithContext(
        address owner,
        IConditionalOrder.ConditionalOrderParams memory params,
        IValueFactory valueFactory,
        bytes memory data,
        bool dispatch
    ) internal {
        vm.prank(owner);
        if (dispatch) {
            vm.expectEmit(true, true, true, true);
            emit ConditionalOrderCreated(owner, params);
        }

        composableCow.createWithContext(params, valueFactory, data, dispatch);
        assertEq(composableCow.singleOrders(owner, keccak256(abi.encode(params))), true);
    }

    /// @dev Removes a single order and checks state
    function _remove(address owner, IConditionalOrder.ConditionalOrderParams memory params) internal {
        bytes32 orderHash = keccak256(abi.encode(params));
        bytes32 ctx = composableCow.cabinet(owner, orderHash);
        vm.prank(owner);
        composableCow.remove(orderHash);
        assertEq(composableCow.singleOrders(owner, orderHash), false);
        if (ctx != bytes32(0)) {
            // ensure that the context was cleared
            assertEq(composableCow.cabinet(owner, orderHash), bytes32(0));
        }
    }

    function getBlankOrder() internal pure returns (GPv2Order.Data memory order) {
        return getOrderWithAppData(keccak256("blank order"));
    }

    function getOrderWithAppData(bytes32 appData) internal pure returns (GPv2Order.Data memory order) {
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

    function createOrder(IConditionalOrder handler, bytes32 salt, bytes memory staticInput)
        internal
        pure
        virtual
        returns (IConditionalOrder.ConditionalOrderParams memory params)
    {
        params = IConditionalOrder.ConditionalOrderParams({
            handler: IConditionalOrder(handler),
            salt: salt,
            staticInput: staticInput
        });
    }

    function getPassthroughOrder() internal view returns (IConditionalOrder.ConditionalOrderParams memory) {
        return createOrder(passThrough, keccak256("pass through order"), hex"");
    }

    function getBundle(Safe safe, uint256 n)
        internal
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
            span: 0,
            appData: keccak256("test.twap")
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

    function emptyProof() internal pure returns (ComposableCoW.Proof memory) {
        return ComposableCoW.Proof({location: 0, data: hex""});
    }
}

contract TestContextSpecifyValue is IValueFactory {
    function getValue(bytes calldata payload) external pure override returns (bytes32) {
        return abi.decode(payload, (bytes32));
    }
}

/// @dev A test swap guard that only allows amounts that are divisible by a given divisor
contract TestSwapGuard is BaseSwapGuard {
    uint256 private divisor;

    constructor(uint256 _divisor) {
        divisor = _divisor;
    }

    // only allow even amounts to be swapped
    function verify(
        GPv2Order.Data calldata order,
        bytes32,
        IConditionalOrder.ConditionalOrderParams calldata,
        bytes calldata
    ) external view returns (bool) {
        return order.sellAmount % divisor == 0;
    }
}

/// @dev A conditional order handler used for testing that returns the GPv2Order passed in as `offchainInput`
contract TestConditionalOrderGenerator is BaseConditionalOrder {
    function getTradeableOrder(address, address, bytes32, bytes calldata, bytes calldata offchainInput)
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
    function verify(
        address,
        address,
        bytes32,
        bytes32,
        bytes32,
        bytes calldata,
        bytes calldata,
        GPv2Order.Data calldata
    ) external pure override {
        // use assembly to set the return data to calldata
        assembly {
            calldatacopy(0, 0, calldatasize())
            revert(0, calldatasize())
        }
    }

    function validateData(bytes calldata) external pure override {
        // --- no-op
    }
}
