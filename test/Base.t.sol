// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import {Enum} from "safe/common/Enum.sol";
import {Safe} from "safe/Safe.sol";
import {SafeProxy} from "safe/proxies/SafeProxy.sol";
import {MultiSend} from "safe/libraries/MultiSend.sol";
import {SignMessageLib} from "safe/libraries/SignMessageLib.sol";

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";
import {GPv2Trade} from "cowprotocol/libraries/GPv2Trade.sol";
import {GPv2Signing} from "cowprotocol/mixins/GPv2Signing.sol";
import {GPv2Settlement} from "cowprotocol/GPv2Settlement.sol";
import {GPv2VaultRelayer} from "cowprotocol/GPv2VaultRelayer.sol";

import "safe/handler/ExtensibleFallbackHandler.sol";

import {ConditionalOrderLib} from "../src/libraries/ConditionalOrderLib.sol";
import {GPv2TradeEncoder} from "./vendored/GPv2TradeEncoder.sol";
import {ComposableCoW} from "../src/ComposableCoW.sol";

import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";
import {SafeLib} from "./libraries/SafeLib.t.sol";
import {IERC20, Tokens} from "./helpers/Tokens.t.sol";
import {CoWProtocol} from "./helpers/CoWProtocol.t.sol";
import {SafeHelper} from "./helpers/Safe.t.sol";

abstract contract Base is Test, Tokens, SafeHelper, CoWProtocol {
    using TestAccountLib for TestAccount[];
    using TestAccountLib for TestAccount;
    using SafeLib for Safe;

    // --- accounts
    TestAccount alice;
    TestAccount bob;
    TestAccount carol;

    Safe public safe1;
    Safe public safe2;
    Safe public safe3;

    function setUp() public virtual override(CoWProtocol) {
        // setup CoWProtocol
        super.setUp();

        // setup test accounts
        alice = TestAccountLib.createTestAccount("alice");
        bob = TestAccountLib.createTestAccount("bob");
        carol = TestAccountLib.createTestAccount("carol");

        // give some tokens to alice and bob
        deal(address(token0), alice.addr, 1000e18);
        deal(address(token1), bob.addr, 1000e18);

        // create a safe with alice, bob and carol as owners and a threshold of 2
        address[] memory owners = new address[](3);
        owners[0] = alice.addr;
        owners[1] = bob.addr;
        owners[2] = carol.addr;

        safe1 = Safe(payable(SafeLib.createSafe(factory, singleton, owners, 2, address(eHandler), 0)));
        safe2 = Safe(payable(SafeLib.createSafe(factory, singleton, owners, 2, address(eHandler), 1)));
        safe3 = Safe(payable(SafeLib.createSafe(factory, singleton, owners, 2, address(eHandler), 2)));
    }

    function signers() internal view returns (TestAccount[] memory) {
        TestAccount[] memory _signers = new TestAccount[](2);
        _signers[0] = alice;
        _signers[1] = bob;
        _signers = TestAccountLib.sortAccounts(_signers);
        return _signers;
    }

    function setFallbackHandler(Safe safe, address handler) internal {
        // do the transaction
        safe.execute(
            address(safe),
            0,
            abi.encodeWithSelector(safe.setFallbackHandler.selector, handler),
            Enum.Operation.Call,
            signers()
        );
    }

    function setSafeMethodHandler(Safe safe, bytes4 selector, bool isStatic, address handler) internal {
        bytes32 encodedHandler = MarshalLib.encode(isStatic, handler);
        safe.execute(
            address(safe),
            0,
            abi.encodeWithSelector(FallbackHandler.setSafeMethod.selector, selector, encodedHandler),
            Enum.Operation.Call,
            signers()
        );
    }

    function safeSignMessage(Safe safe, bytes memory message) internal {
        safe.execute(
            address(signMessageLib),
            0,
            abi.encodeWithSelector(signMessageLib.signMessage.selector, message),
            Enum.Operation.DelegateCall,
            signers()
        );
    }

    // function createOrder(Safe safe, bytes memory conditionalOrder, IERC20 sellToken, uint256 sellAmount)
    //     internal
    // {
    //     createOrderWithEnv(
    //         settlement, relayer, multisend, signMessageLib, safe, conditionalOrder, sellToken, sellAmount
    //     );
    // }

    // function createOrderWithEnv(
    //     GPv2Settlement settlement,
    //     address relayer,
    //     MultiSend multiSend,
    //     SignMessageLib signMessageLib,
    //     Safe safe,
    //     bytes memory conditionalOrder,
    //     IERC20 sellToken,
    //     uint256 sellAmount
    // ) internal {
    //     // Hash of the conditional order to sign
    //     bytes32 typedHash = ConditionalOrderLib.hash(conditionalOrder, settlement.domainSeparator());

    //     bytes memory signMessageTx = abi.encodeWithSelector(signMessageLib.signMessage.selector, abi.encode(typedHash));

    //     bytes memory approveTx = abi.encodeWithSelector(sellToken.approve.selector, relayer, sellAmount);

    //     bytes memory dispatchTx =
    //         abi.encodeWithSelector(CoWFallbackHandler(address(safe)).dispatch.selector, conditionalOrder);

    //     /// @dev Using the `multisend` contract to batch multiple transactions
    //     safe.execute(
    //         address(multiSend),
    //         0,
    //         abi.encodeWithSelector(
    //             multiSend.multiSend.selector,
    //             abi.encodePacked(
    //                 // 1. sign the conditional order
    //                 abi.encodePacked(
    //                     uint8(Enum.Operation.DelegateCall),
    //                     address(signMessageLib),
    //                     uint256(0),
    //                     signMessageTx.length,
    //                     signMessageTx
    //                 ),
    //                 // 2. approve the tokens to be spent by the settlement contract
    //                 abi.encodePacked(Enum.Operation.Call, address(sellToken), uint256(0), approveTx.length, approveTx),
    //                 // 3. dispatch the conditional order
    //                 abi.encodePacked(Enum.Operation.Call, address(safe), uint256(0), dispatchTx.length, dispatchTx)
    //             )
    //         ),
    //         Enum.Operation.DelegateCall,
    //         signers()
    //     );
    // }

    function settlePart(SafeProxy proxy, GPv2Order.Data memory order, bytes memory bundleBytes) internal {
        // Generate Bob's counter order
        GPv2Order.Data memory bobOrder = GPv2Order.Data({
            sellToken: order.buyToken,
            buyToken: order.sellToken,
            receiver: address(0),
            sellAmount: order.buyAmount,
            buyAmount: order.sellAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_BUY,
            partiallyFillable: false,
            buyTokenBalance: GPv2Order.BALANCE_ERC20,
            sellTokenBalance: GPv2Order.BALANCE_ERC20
        });

        bytes memory bobSignature =
            TestAccountLib.signPacked(bob, GPv2Order.hash(bobOrder, settlement.domainSeparator()));

        // Authorize the GPv2VaultRelayer to spend bob's sell token
        vm.prank(bob.addr);
        IERC20(bobOrder.sellToken).approve(address(relayer), bobOrder.sellAmount);

        // first declare the tokens we will be trading
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(order.sellToken);
        tokens[1] = IERC20(order.buyToken);

        // second declare the clearing prices
        uint256[] memory clearingPrices = new uint256[](2);
        clearingPrices[0] = bobOrder.sellAmount;
        clearingPrices[1] = bobOrder.buyAmount;

        // third declare the trades
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](2);

        // The safe's order is the first trade
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: address(0),
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: GPv2TradeEncoder.encodeFlags(order, GPv2Signing.Scheme.Eip1271),
            executedAmount: order.sellAmount,
            signature: abi.encodePacked(address(proxy), bundleBytes)
        });

        // Bob's order is the second trade
        trades[1] = GPv2Trade.Data({
            sellTokenIndex: 1,
            buyTokenIndex: 0,
            receiver: address(0),
            sellAmount: bobOrder.sellAmount,
            buyAmount: bobOrder.buyAmount,
            validTo: bobOrder.validTo,
            appData: bobOrder.appData,
            feeAmount: bobOrder.feeAmount,
            flags: GPv2TradeEncoder.encodeFlags(bobOrder, GPv2Signing.Scheme.Eip712),
            executedAmount: bobOrder.sellAmount,
            signature: bobSignature
        });

        // fourth declare the interactions
        GPv2Interaction.Data[][3] memory interactions =
            [new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0), new GPv2Interaction.Data[](0)];

        // finally we can execute the settlement
        vm.prank(solver.addr);
        settlement.settle(tokens, clearingPrices, trades, interactions);
    }
}
