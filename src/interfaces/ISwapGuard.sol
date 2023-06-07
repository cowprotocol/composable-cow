// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

import {IConditionalOrder} from "./IConditionalOrder.sol";

/**
 * @title SwapGuard Interface - Restrict CoW Protocol settlement for an account using `ComposableCoW`.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
interface ISwapGuard is IERC165 {
    /**
     * @notice Verify that the order is allowed to be settled via CoW Protocol.
     * @param order The order to verify.
     * @param ctx The context of the order (bytes32(0) if a merkle tree is used, otherwise H(params))
     * @param params The conditional order parameters (handler, salt, staticInput).
     * @param offchainInput Any offchain input to verify.
     * @return True if the order is allowed to be settled via CoW Protocol.
     */
    function verify(
        GPv2Order.Data calldata order,
        bytes32 ctx,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput
    ) external view returns (bool);
}
