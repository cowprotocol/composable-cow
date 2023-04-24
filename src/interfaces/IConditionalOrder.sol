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

    /**
    /**
     * Verify if a given discrete order is valid.
     * @dev Used in combination with `isValidSafeSignature` to verify that the order is signed by the Safe.
     * @param owner the contract who is the owner of the order
     * @param sender the `msg.sender` of the transaction
     * @param _hash the hash of the order
     * @param domainSeparator the domain separator used to sign the order
     * @param staticInput the static input for all discrete orders cut from this conditional order
     * @param offchainInput dynamic off-chain input for a discrete order cut from this conditional order
     * @return true if the order is valid, false otherwise
     */
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata order
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
     * @param sender the `msg.sender` of the parent `isValidSignature` call
     * @param staticInput the static input for all discrete orders cut from this conditional order
     * @param offchainInput dynamic off-chain input for a discrete order cut from this conditional order
     * @return the tradeable order for submission to the CoW Protocol API
     */
    function getTradeableOrder(address owner, address sender, bytes calldata staticInput, bytes calldata offchainInput)
        external
        view
        returns (GPv2Order.Data memory);
}
