// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import "./interfaces/IConditionalOrder.sol";

/**
 * @title Base logic for conditional orders.
 * @dev Enforces the order verification logic for conditional orders, allowing developers
 *      to focus on the logic for generating the tradeable order.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract BaseConditionalOrder is IConditionalOrder, IConditionalOrderGenerator {
    /**
     * @inheritdoc IConditionalOrder
     */
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata
    ) external view override returns (bool) {
        GPv2Order.Data memory generatedOrder = getTradeableOrder(owner, sender, staticInput, offchainInput);

        /// @dev Verify that the order is valid and matches the payload.
        if (_hash != GPv2Order.hash(generatedOrder, domainSeparator)) {
            revert IConditionalOrder.OrderNotValid();
        } else {
            return true;
        }
    }

    /**
     * @dev Set the visibility of this function to `public` to allow `verify` to call it.
     * @inheritdoc IConditionalOrderGenerator
     */
    function getTradeableOrder(address owner, address sender, bytes calldata staticInput, bytes calldata offchainInput)
        public
        view
        virtual
        override
        returns (GPv2Order.Data memory);

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return interfaceId == type(IConditionalOrderGenerator).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
