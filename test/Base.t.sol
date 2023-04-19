// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

import {TestAccount, TestAccountLib} from "./libraries/TestAccountLib.t.sol";

import "./helpers/CoWProtocol.t.sol";
import "./helpers/Safe.t.sol";

abstract contract Base is Test, SafeHelper, CoWProtocol {
    using TestAccountLib for TestAccount[];
    using TestAccountLib for TestAccount;

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

    function signers() internal view override returns (TestAccount[] memory) {
        TestAccount[] memory _signers = new TestAccount[](2);
        _signers[0] = alice;
        _signers[1] = bob;
        _signers = TestAccountLib.sortAccounts(_signers);
        return _signers;
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

}
