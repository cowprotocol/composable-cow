// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @title Watchtower Custom Error Interface
 * @author CoW Protocol Developers
 * @dev An interface that collects all custom error message for the watchtower.
 * Different error messages lead to different watchtower behaviors when creating
 * an order.
 * @dev The watchtower is a service that automatically posts orders to the CoW
 * Protocol orderbook at regular intervals.
 */
contract IWatchtowerCustomErrors {
    /**
     * No order is currently available for trading, but the watchtower should
     * try again at the specified block.
     */
    error PollTryAtBlock(uint256 blockNumber, string message);
}
