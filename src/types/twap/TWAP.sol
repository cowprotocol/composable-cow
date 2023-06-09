// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "../../ComposableCoW.sol";

import "../../BaseConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";

/**
 * @title TWAP Conditional Order
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @notice TWAP conditional orders allow for splitting an order into a series of orders that are
 * executed at a fixed interval. This is useful for ensuring that a trade is executed at a
 * specific price, even if the price of the token changes during the trade.
 * @dev Designed to be used with the CoW Protocol Conditional Order Framework.
 */
contract TWAP is BaseConditionalOrder {
    ComposableCoW private immutable composableCow;

    constructor(ComposableCoW _composableCow) {
        composableCow = _composableCow;
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev `owner`, `sender` and `offchainInput` is not used.
     */
    function getTradeableOrder(address owner, address, bytes32 ctx, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        /**
         * @dev Decode the payload into a TWAP bundle and get the order. `orderFor` will revert if
         * there is no current valid order.
         * NOTE: This will return an order even if the part of the TWAP bundle that is currently
         * valid is filled. This is safe as CoW Protocol ensures that each `orderUid` is only
         * settled once.
         */
        TWAPOrder.Data memory twap = abi.decode(staticInput, (TWAPOrder.Data));

        /**
         * @dev If `twap.t0` is set to 0, then get the start time from the context.
         */
        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }

        order = TWAPOrder.orderFor(twap);

        /// @dev Revert if the order is outside the TWAP bundle's span.
        if (!(block.timestamp <= order.validTo)) {
            revert IConditionalOrder.OrderNotValid();
        }
    }
}
