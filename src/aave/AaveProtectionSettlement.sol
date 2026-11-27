// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {GPv2Signing} from "cowprotocol/contracts/mixins/GPv2Signing.sol";

import {ICowSettlement} from "../../lib/flash-loan-router/src/interface/ICowSettlement.sol";
import {Loan} from "../../lib/flash-loan-router/src/library/Loan.sol";
import {ComposableCoW} from "../ComposableCoW.sol";
import {IConditionalOrder} from "../interfaces/IConditionalOrder.sol";
import {IAavePositionProtector} from "./interfaces/IAavePositionProtector.sol";

/// @notice Finds the protection rule carried by a standard CoW router settlement.
library AaveProtectionSettlement {
    uint256 private constant ROUTER_HEADER_SIZE = 32;
    uint256 private constant SIGNER_SIZE = 20;

    /// @dev The router prepends the remaining loan count and appends fixed-width loans to the settlement.
    ///      The executor can serve one of its own trades per settlement. Other owners may be batched.
    function ruleId(bytes calldata data, IConditionalOrder handler) internal view returns (bytes32 id) {
        uint256 remainingLoans = uint256(bytes32(data[:ROUTER_HEADER_SIZE]));
        bytes calldata settlement = data[ROUTER_HEADER_SIZE:data.length - remainingLoans * Loan.ENCODED_LOAN_BYTE_SIZE];
        if (bytes4(settlement[:4]) != ICowSettlement.settle.selector) revert IAavePositionProtector.InvalidLoan();

        // Read only the trade array at its ABI offset. CoW decodes the other fields at settlement.
        (,, GPv2Trade.Data[] memory trades) = abi.decode(settlement[4:], (uint256, uint256, GPv2Trade.Data[]));
        for (uint256 i; i < trades.length; ++i) {
            GPv2Trade.Data memory trade = trades[i];
            if (trade.receiver != address(this) || trade.signature.length <= SIGNER_SIZE) continue;
            (,,,, GPv2Signing.Scheme scheme) = GPv2Trade.extractFlags(trade.flags);
            if (scheme != GPv2Signing.Scheme.Eip1271) continue;

            bytes memory signature = trade.signature;
            if (address(bytes20(signature)) != address(this)) continue;
            // Reject another match so the loan identifies exactly one trade.
            if (id != bytes32(0)) revert IAavePositionProtector.InvalidLoan();

            // CoW prefixes the forwarder's ABI signature with the 20-byte ERC-1271 signer.
            bytes memory payload = new bytes(signature.length - SIGNER_SIZE);
            assembly ("memory-safe") {
                mcopy(add(payload, 32), add(add(signature, 32), SIGNER_SIZE), mload(payload))
            }
            (, ComposableCoW.PayloadStruct memory auth) =
                abi.decode(payload, (GPv2Order.Data, ComposableCoW.PayloadStruct));
            id = abi.decode(auth.params.staticInput, (bytes32));
            if (auth.params.handler != handler || id == bytes32(0)) {
                revert IAavePositionProtector.InvalidLoan();
            }
        }
        if (id == bytes32(0)) revert IAavePositionProtector.InvalidLoan();
    }
}
