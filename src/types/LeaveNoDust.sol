// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "../BaseConditionalOrder.sol";

import "../BaseConditionalOrder.sol";

/**
 * @title A smart contract that executes a trade at the specified exchange rate for the entirety of the current balance.
 * @dev Designed to be used with the CoW Protocol Conditional Order Framework.
 *      This order may be used e.g. if a rebasing token is intended to be fully sold, but its balance keeps changing from 
 *      block to block making it hard to specify a fixed amount up-front.
 *      It is recommended to use sell and buy amounts from a verified quote to ensure the trade is likely to execute.
 *      In case the sell balance at the time of execution differs significantly from the one at the time of order placement,
 *      additional care in accounting for price impact and the slippage tolerance may be needed.
 *      In particular, since the price is scaled linearly, however quotes include a non-linear network cost as part of the exchange rate,
 *      having a significantly lower sell amount, scaled linearly may not allow for sufficient network fee be taken from surplus.
 */
contract LeaveNoDust is BaseConditionalOrder {
    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        address receiver;
        uint32 validity;
        bytes32 appData;
    }

    /**
     * @inheritdoc IConditionalOrderGenerator
     * @dev Return the specified sell order using the current total balance and the specified exchange rate
     */
    function getTradeableOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        /// @dev Decode the smart order payload into the trade parameters.
        LeaveNoDust.Data memory data = abi.decode(staticInput, (Data));

        // Adjust the buy amount by the current owner's balance
        uint256 sellAmount = data.sellToken.balanceOf(owner);
        uint256 buyAmount = sellAmount * data.buyAmount / data.sellAmount;
        
        // ensures that orders queried shortly after one another result in the same hash (to avoid spamming the orderbook)
        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.receiver,
            sellAmount,
            buyAmount,
            data.validity,
            data.appData,
            0, // this field is no longer relevant and has to be 0
            GPv2Order.KIND_SELL,
            false, // fill or kill
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}
