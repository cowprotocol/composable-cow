// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {ConditionalOrder} from "../../interfaces/ConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";

/// @title CoW TWAP Fallback Handler
/// @author mfw78 <mfw78@rndlabs.xyz>
/// @dev A fallback handler to enable TWAP conditional orders on Safe, settling via CoW Protocol.
contract TWAP is ConditionalOrder {

    function getTradeableOrder(address owner, address sender, bytes calldata payload) external view override returns (GPv2Order.Data memory order) {
        owner;
        sender;

        /// @dev Decode the payload into a TWAP bundle and get the order. `orderFor` will revert if
        /// there is no current valid order.
        /// NOTE: This will return an order even if the part of the TWAP bundle that is currently
        /// valid is filled. This is safe as CoW Protocol ensures that each `orderUid` is only
        /// settled once.
        order = TWAPOrder.orderFor(abi.decode(payload, (TWAPOrder.Data)));

        /// @dev Revert if the order is outside the TWAP bundle's span.
        if (!(block.timestamp <= order.validTo)) revert ConditionalOrder.OrderNotValid();
    }

}
