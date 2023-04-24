// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "./BaseGuard.sol";

/**
 * @title A Swap Guard that only allows orders with a receiver of 0x0 (ie. self)
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
contract ReceiverLock is BaseGuard {
    /**
     * Only allow orders with a receiver of 0x0 (ie. self)
     * @param order The order being verified
     */
    function verify(GPv2Order.Data calldata order, IConditionalOrder.ConditionalOrderParams calldata, bytes calldata)
        external
        pure
        override
        returns (bool)
    {
        return order.receiver == address(0);
    }
}
