// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";
import {ISafeSignatureVerifier} from "safe/handler/extensible/SignatureVerifierMuxer.sol";

/**
 * @dev The conditional order EIP-712 `typeHash` for creating an order.
 * 
 * This value is pre-computed from the following expression:
 * ```
 * keccak256(
 *    "ConditionalOrder(" +
 *       "bytes payload" +
 *   ")"
 * )
 * ```
 * The `payload` parameter is the implementation-specific payload used to create the order.
 */
bytes32 constant CONDITIONAL_ORDER_TYPE_HASH = hex"59a89a42026f77464983113514109ddff8e510f0e62c114303617cb5ca97e091";

/**
 * @dev The conditional order EIP-712 `typeHash` for a cancelled order.
 * 
 * This value is pre-computed from the following expression:
 * ```
 * keccak256(
 *      "CancelOrder(" +
 *          "bytes32 order" +
 *      ")" 
 * )
 * ```
 * The `order` parameter is the `hashStruct` of the `ConditionalOrder`.
 */
bytes32 constant CANCEL_ORDER_TYPE_HASH = hex"e2d395a4176e36febca53784f02b9bf31a44db36d5688fe8fc4306e6dfa54148";

/**
 * @title Conditional Order Interface
 * @author CoW Protocol Developers + mfw78 <mfw78@rndlabs.xyz>
 * @dev This interface is an extended version of `ConditionalOrder` as found at the repository:
 *      https://github.com/cowprotocol/conditional-smart-orders/blob/main/src/ConditionalOrder.sol. The differences are:
 *      - Event `ConditionalOrderCreated` contains both the `address` of the Safe that implements the `getTradeableOrder`
 *        function and the `bytes` parameter representing the conditional order.
 *      - Function `dispatch` dedicated to emitting the `ConditionalOrderCreated` event.
 *      - Function `getTradeableOrder` takes the `bytes` parameter representing the conditional order as input.
 */
interface ConditionalOrder is ISafeSignatureVerifier {
    /// @dev This error is returned by the `getTradeableOrder` function if the order condition is not met.
    error OrderNotValid();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is not signed.
    error OrderNotSigned();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is expired.
    error OrderExpired();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is cancelled.
    error OrderCancelled();

    struct PayloadStruct {
        GPv2Order.Data order;
        bytes data;
    }

    /**
     * Verify if a given order is valid. This function is used in combination with the `isValidSafeSignature`
     * function to verify that the order is signed by the Safe.
     * @param owner the contract who is the owner of the order
     * @param sender the `msg.sender` of the transaction
     * @param hash the hash of the order
     * @param payload the payload struct containing the order and the implementation-specific payload
     * @return true if the order is valid, false otherwise
     */
    function verify(address owner, address sender, bytes32 hash, PayloadStruct calldata payload)
        external
        view
        returns (bool);
}

interface ConditionalOrderFactory is ConditionalOrder {
    /**
     * @dev This event is emitted when a new conditional order is created.
     * @param safe the address of the Safe that implements the `getTradeableOrder` function
     * @param payload the payload struct containing the order and the implementation-specific payload
     */
    event ConditionalOrderCreated(address indexed safe, bytes payload);

    /**
     * @dev This function is used to dispatch the `ConditionalOrderCreated` event.
     * @param safe the address of the Safe that implements the `getTradeableOrder` function
     * @param payload the payload struct containing the order and the implementation-specific payload
     */
    function dispatch(address safe, address sender, bytes calldata payload) external;

    /**
     * @dev Get a tradeable order that can be posted to the CoW Protocol API and would pass signature validation.
     *     Reverts if the order condition is not met.
     * @param owner the contract who is the owner of the order
     * @param sender the `msg.sender` of the transaction
     * @param payload The implementation-specific payload used to create the order, as emitted by the
     *       ConditionalOrderCreated event
     * @return a payload struct containing the order and the implementation-specific payload
     */
    function getTradeableOrder(address owner, address sender, bytes calldata payload)
        external
        view
        returns (PayloadStruct memory);
}