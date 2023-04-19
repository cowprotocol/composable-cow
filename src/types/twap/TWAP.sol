// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import "../../interfaces/IConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";

/// @title CoW TWAP Fallback Handler
/// @author mfw78 <mfw78@rndlabs.xyz>
/// @dev A fallback handler to enable TWAP conditional orders on Safe, settling via CoW Protocol.
contract TWAP is IConditionalOrderFactory {
    function getTradeableOrder(address owner, address sender, bytes memory data)
        public
        view
        override
        returns (GPv2Order.Data memory order, bytes memory)
    {
        owner;
        sender;

        /// @dev Decode the payload into a TWAP bundle and get the order. `orderFor` will revert if
        /// there is no current valid order.
        /// NOTE: This will return an order even if the part of the TWAP bundle that is currently
        /// valid is filled. This is safe as CoW Protocol ensures that each `orderUid` is only
        /// settled once.
        order = TWAPOrder.orderFor(abi.decode(data, (TWAPOrder.Data)));

        /// @dev Revert if the order is outside the TWAP bundle's span.
        if (!(block.timestamp <= order.validTo)) {
            revert IConditionalOrder.OrderNotValid();
        }
    }

    function verify(address owner, address sender, bytes32 _hash, bytes32 domainSeparator, GPv2Order.Data calldata, bytes calldata data)
        external
        view
        override
        returns (bool)
    {
        (GPv2Order.Data memory generatedOrder,) = getTradeableOrder(owner, sender, data);

        /// @dev Verify that the order is valid and matches the payload.
        if (_hash != GPv2Order.hash(generatedOrder, domainSeparator)) {
            revert IConditionalOrder.OrderNotValid();
        } else {
            return true;
        }
    }

    function dispatch(address safe, address sender, bytes calldata payload) external override {}
}
