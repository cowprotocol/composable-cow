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

        // give some tokens to the safe
        deal(address(token0), address(safe1), 1000e18);
    }

    function signers() internal view override returns (TestAccount[] memory) {
        TestAccount[] memory _signers = new TestAccount[](2);
        _signers[0] = alice;
        _signers[1] = bob;
        _signers = TestAccountLib.sortAccounts(_signers);
        return _signers;
    }
}
