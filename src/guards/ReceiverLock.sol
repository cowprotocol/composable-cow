// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "../interfaces/ISwapGuard.sol";

contract ReceiverLock is ISwapGuard {
    /**
     * Only allow orders with a receiver of 0x0 (ie. self)
     * @param order The order being verified
     * @param payload Any additional data needed to verify the order (unused) 
     */
    function verify(GPv2Order.Data calldata order, bytes calldata payload)
        external
        pure
        override
        returns (bool)
    {
        payload;
        return order.receiver == address(0);
    }
}