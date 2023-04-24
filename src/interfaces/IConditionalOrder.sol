// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

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
interface IConditionalOrder {
    /// @dev This error is returned by the `getTradeableOrder` function if the order condition is not met.
    error OrderNotValid();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is not signed.
    error OrderNotSigned();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is expired.
    error OrderExpired();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is cancelled.
    error OrderCancelled();

    /**
     * Verify if a given order is valid. This function is used in combination with the `isValidSafeSignature`
     * function to verify that the order is signed by the Safe.
     * @param owner the contract who is the owner of the order
     * @param sender the `msg.sender` of the transaction
     * @param hash the hash of the order
     * @param domainSeparator the domain separator used to sign the order
     * @param order that is being verified (passed from `encodeData`)
     * @param payload any additional implementation payload that is needed to verify the order
     * @return true if the order is valid, false otherwise
     */
    function verify(
        address owner,
        address sender,
        bytes32 hash,
        bytes32 domainSeparator,
        GPv2Order.Data calldata order,
        bytes calldata payload
    ) external view returns (bool);
}

interface IConditionalOrderFactory is IConditionalOrder {
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
     * @return the tradeable order and the implementation-specific payload
     */
    function getTradeableOrder(address owner, address sender, bytes calldata payload)
        external
        view
        returns (GPv2Order.Data memory, bytes memory);
}
