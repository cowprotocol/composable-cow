// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

/**
 * @title SwapGuard Interface - Filter out orders that are not allowed to be settled via CoW Protocol.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
interface ISwapGuard {
    /**
     * @notice Verify that the order is allowed to be settled via CoW Protocol.
     * @param order The order to verify.
     * @param data The data to verify.
     * @return True if the order is allowed to be settled via CoW Protocol.
     */
    function verify(GPv2Order.Data calldata order, bytes calldata data) external view returns (bool);
}
