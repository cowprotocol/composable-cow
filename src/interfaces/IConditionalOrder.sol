// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";
import {GPv2Interaction} from "cowprotocol/libraries/GPv2Interaction.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

/**
 * @title Conditional Order Interface
 * @author CoW Protocol Developers + mfw78 <mfw78@rndlabs.xyz>
 */
interface IConditionalOrder {
    /// @dev This error is returned by the `getTradeableOrder` function if the order condition is not met.
    error OrderNotValid();

    /**
     * @dev This struct is used to uniquely identify a conditional order for an owner.
     *      H(handler || salt || staticInput) **MUST** be unique for an owner.
     */
    struct ConditionalOrderParams {
        IConditionalOrder handler;
        bytes32 salt;
        bytes staticInput;
    }

    struct Interactions {
        GPv2Interaction.Data[] pre;
        GPv2Interaction.Data[] post;
    }

    /**
     * Verify if a given discrete order is valid.
     * @dev Used in combination with `isValidSafeSignature` to verify that the order is signed by the Safe.
     *      **MUST** revert if the order condition is not met.
     * @param owner the contract who is the owner of the order
     * @param sender the `msg.sender` of the transaction
     * @param _hash the hash of the order
     * @param domainSeparator the domain separator used to sign the order
     * @param ctx the context of the order (bytes32(0) if a merkle tree is used, otherwise H(params))
     * @param staticInput the static input for all discrete orders cut from this conditional order
     * @param offchainInput dynamic off-chain input for a discrete order cut from this conditional order
     */
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata order
    ) external view;
}

/**
 * @title Conditional Order Generator Interface
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
interface IConditionalOrderGenerator is IConditionalOrder, IERC165 {
    /**
     * @dev This event is emitted when a new conditional order is created.
     * @param owner the address that has created the conditional order
     * @param params the address / salt / data of the conditional order
     */
    event ConditionalOrderCreated(address indexed owner, IConditionalOrder.ConditionalOrderParams params);

    /**
     * @dev Get a tradeable order that can be posted to the CoW Protocol API and would pass signature validation.
     *      **MUST** revert if the order condition is not met.
     * @param owner the contract who is the owner of the order
     * @param sender the `msg.sender` of the parent `isValidSignature` call
     * @param ctx the context of the order (bytes32(0) if merkle tree is used, otherwise the H(params))
     * @param staticInput the static input for all discrete orders cut from this conditional order
     * @param offchainInput dynamic off-chain input for a discrete order cut from this conditional order
     * @return the tradeable order for submission to the CoW Protocol API
     */
    function getTradeableOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) external view returns (GPv2Order.Data memory, Interactions memory);
}
