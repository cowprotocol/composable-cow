// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";

struct TestAccount {
    address addr;
    uint256 pk;
}

library TestAccountLib {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev Creates a new TestAccount with the provided user name.
    ///      Logic borrows from `StdCheats.sol`.
    function createTestAccount(string memory user) internal returns (TestAccount memory) {
        uint256 pk = uint256(keccak256(abi.encodePacked(user)));
        address addr = vm.addr(pk);
        vm.label(addr, user);
        return TestAccount(addr, pk);
    }

    /// @dev Sign the provided hash with the provided TestAccount.
    /// @param account The TestAccount to sign with.
    /// @param hash The hash to sign.
    /// @return The signature.
    function signPacked(TestAccount memory account, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(account.pk, hash);

        bytes memory signature = new bytes(65);
        signature = abi.encodePacked(r, s, v);
        return signature;
    }

    /// @dev Sorts an array of TestAccounts by address.
    /// @param accounts The array of TestAccounts to sort.
    /// @return The sorted array of TestAccounts.
    function sortAccounts(TestAccount[] memory accounts) internal pure returns (TestAccount[] memory) {
        for (uint256 i = 0; i < accounts.length; i++) {
            for (uint256 j = i + 1; j < accounts.length; j++) {
                if (accounts[i].addr > accounts[j].addr) {
                    TestAccount memory tmp = accounts[i];
                    accounts[i] = accounts[j];
                    accounts[j] = tmp;
                }
            }
        }
        return accounts;
    }
}
