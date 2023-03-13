// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

/// @dev The conditional order EIP-712 `typeHash` for creating an order.
///
/// This value is pre-computed from the following expression:
/// ```
/// keccak256(
///     "ConditionalOrder(" +
///         "bytes payload" +
///     ")"
/// )
/// ```
/// The `payload` parameter is the implementation-specific payload used to create the order.
bytes32 constant CONDITIONAL_ORDER_TYPE_HASH = hex"59a89a42026f77464983113514109ddff8e510f0e62c114303617cb5ca97e091";

/// @dev The conditional order EIP-712 `typeHash` for a cancelled order.
///
/// This value is pre-computed from the following expression:
/// ```
/// keccak256(
///     "CancelOrder(" +
///         "bytes32 order" +
///     ")"
/// )
/// ```
/// The `order` parameter is the `hashStruct` of the `ConditionalOrder`.
bytes32 constant CANCEL_ORDER_TYPE_HASH = hex"e2d395a4176e36febca53784f02b9bf31a44db36d5688fe8fc4306e6dfa54148";

/// @title Conditional Order Interface
/// @author CoW Protocol Developers + mfw78 <mfw78@rndlabs.xyz>
/// @dev This interface is an extended version of `ConditionalOrder` as found at the repository:
/// https://github.com/cowprotocol/conditional-smart-orders/blob/main/src/ConditionalOrder.sol. The differences are:
/// - Event `ConditionalOrderCreated` contains both the `address` of the Safe that implements the `getTradeableOrder`
///   function and the `bytes` parameter representing the conditional order.
/// - Function `dispatch` dedicated to emitting the `ConditionalOrderCreated` event.
/// - Function `getTradeableOrder` takes the `bytes` parameter representing the conditional order as input.
interface ConditionalOrder {
    /// @dev This error is returned by the `getTradeableOrder` function if the order condition is not met.
    error OrderNotValid();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is not signed.
    error OrderNotSigned();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is expired.
    error OrderExpired();
    /// @dev This error is returned by the `getTradeableOrder` function if the order is cancelled.
    error OrderCancelled();

    /// @dev This event is emitted by the Safe when a conditional order is created.
    ///      The `address` of the Safe that implements the `getTradeableOrder` function.
    ///      The `bytes` parameter is the abi-encoded order that is passed to the CoW Protocol API
    ///      the signature bytes.
    event ConditionalOrderCreated(address indexed, bytes);

    /// @dev Using the `payload` supplied, create a conditional order that can be posted to the CoW Protocol API. The
    ///      payload may be mutated by the function to create the order, which is then emitted as a
    ///      `ConditionalOrderCreated` event.
    /// @param payload The implementation-specific payload used to create the order
    function dispatch(bytes calldata payload) external;

    /// @dev Get a tradeable order that can be posted to the CoW Protocol API and would pass signature validation.
    ///      Reverts if the order condition is not met.
    /// @param payload The implementation-specific payload used to create the order, as emitted by the
    ///        ConditionalOrderCreated event
    /// @return order to be posted to the CoW Protocol API
    function getTradeableOrder(bytes calldata payload) external view returns (GPv2Order.Data memory);
}
