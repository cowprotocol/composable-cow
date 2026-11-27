// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";

import {BaseConditionalOrder} from "../BaseConditionalOrder.sol";
import {IConditionalOrder, IConditionalOrderGenerator} from "../interfaces/IConditionalOrder.sol";
import {IAavePositionProtector} from "./interfaces/IAavePositionProtector.sol";

/// @notice Generates a full-fill sell order for a registered rule on the shared executor.
contract AavePositionProtectionHandler is BaseConditionalOrder {
    /// @notice Amounts in token base units and an expiry for one fill.
    /// @dev The watcher supplies the exact appData bytes after the authenticated rule ID.
    struct Quote {
        uint256 sellAmount;
        uint256 buyAmount;
        string appDataSuffix;
        uint32 validTo;
    }

    /// @inheritdoc IConditionalOrderGenerator
    /// @dev The executor checks the standing rule. The signed sell amount equals the flash loan principal.
    function getTradeableOrder(
        address owner,
        address sender,
        bytes32,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) public view override returns (GPv2Order.Data memory) {
        // Without a quote, ask pollers to keep the rule and try again.
        if (offchainInput.length == 0) revert IConditionalOrder.PollTryNextBlock("repayment quote required");
        Quote memory quote = abi.decode(offchainInput, (Quote));
        if (quote.buyAmount == 0) {
            revert IConditionalOrder.OrderNotValid("invalid repayment quote");
        }

        // ComposableCoW authenticates staticInput as part of the registered order.
        bytes32 ruleId = abi.decode(staticInput, (bytes32));
        (address sellToken, address buyToken) =
            IAavePositionProtector(owner).validateOrder(ruleId, quote.sellAmount, quote.validTo, sender);

        // Borrowers share the same CoW owner, so bind the rule ID into the digest at the start of appData.
        // Watch Tower writes the rest of the JSON in the same byte order.
        bytes32 appData = keccak256(
            abi.encodePacked(
                '{"metadata":{"utm":{"utmContent":"aave-rule-',
                Strings.toHexString(uint256(ruleId), 32),
                '"',
                quote.appDataSuffix
            )
        );

        return GPv2Order.Data({
            sellToken: IERC20(sellToken),
            buyToken: IERC20(buyToken),
            receiver: owner,
            sellAmount: quote.sellAmount,
            buyAmount: quote.buyAmount,
            validTo: quote.validTo,
            appData: appData,
            // The signed sell amount already includes the quoted fee and matches the flash loan.
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
