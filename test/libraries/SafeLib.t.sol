// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Enum} from "safe/common/Enum.sol";
import {Safe} from "safe/Safe.sol";
import {SafeProxy} from "safe/proxies/SafeProxy.sol";
import {SafeProxyFactory} from "safe/proxies/SafeProxyFactory.sol";
import {CompatibilityFallbackHandler} from "safe/handler/CompatibilityFallbackHandler.sol";
import {MultiSend} from "safe/libraries/MultiSend.sol";
import {SignMessageLib} from "safe/libraries/SignMessageLib.sol";

import {TestAccount, TestAccountLib} from "../libraries/TestAccountLib.t.sol";

library SafeLib {
    using TestAccountLib for TestAccount[];
    using TestAccountLib for TestAccount;

    /// @dev Creates a new Gnosis Safe proxy with the provided owners and
    /// threshold.
    /// @param owners The list of owners of the Gnosis Safe.
    /// @param threshold The number of owners required to confirm a transaction.
    /// @return safe The Gnosis Safe proxy.
    function createSafe(
        SafeProxyFactory factory,
        Safe singleton,
        address[] memory owners,
        uint256 threshold,
        address handler,
        uint256 nonce
    ) internal returns (SafeProxy) {
        return SafeProxy(
            factory.createProxyWithNonce(
                address(singleton),
                abi.encodeWithSelector(
                    Safe.setup.selector, owners, threshold, address(0), "", handler, address(0), 0, address(0)
                ),
                nonce // nonce
            )
        );
    }

    // @dev Executes a transaction on a Gnosis Safe proxy with the provided accounts as signatories.
    // @param safe The Gnosis Safe proxy.
    // @param to The address to which the transaction is sent. If set to 0x0, the transaction is sent to the Safe.
    // @param value The amount of Ether to be sent with the transaction.
    // @param data The data to be sent with the transaction.
    // @param operation The operation to be performed.
    // @param signers The accounts that will sign the transaction.
    function execute(
        Safe safe,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        TestAccount[] memory signers
    ) internal {
        uint256 nonce = safe.nonce();
        bytes32 setHandlerTx =
            safe.getTransactionHash(to, value, data, operation, 0, 0, 0, address(0), address(0), nonce);

        // sign the transaction by alice and bob (sort their account by ascending order)
        signers = signers.sortAccounts();

        bytes memory signatures;
        for (uint256 i = 0; i < signers.length; i++) {
            signatures = abi.encodePacked(signatures, signers[i].signPacked(setHandlerTx));
        }

        // execute the transaction
        safe.execTransaction(to, value, data, operation, 0, 0, 0, address(0), payable(0), abi.encodePacked(signatures));
    }

    function executeSingleOwner(
        Safe safe,
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        address owner
    ) internal {
        bytes memory signature = abi.encodePacked(uint256(uint160(owner)), bytes32(0), bytes1(0x01));

        // execute the transaction
        safe.execTransaction(to, value, data, operation, 0, 0, 0, address(0), payable(0), signature);
    }
}
