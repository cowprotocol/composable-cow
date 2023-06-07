// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "@openzeppelin/interfaces/IERC20.sol";

import "../BaseConditionalOrder.sol";

// @title A smart contract that trades whenever its balance of a certain token exceeds a target threshold
contract TradeAboveThreshold is BaseConditionalOrder {
    using GPv2Order for GPv2Order.Data;

    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address target;
        uint256 threshold;
    }

    // @dev If the `owner`'s balance of `sellToken` is above the specified threshold, sell its entire balance
    // for `buyToken` at the current market price (no limit!).
    function getTradeableOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        /// @dev Decode the payload into the trade above threshold parameters.
        TradeAboveThreshold.Data memory data = abi.decode(staticInput, (Data));

        uint256 balance = data.sellToken.balanceOf(owner);
        require(balance >= data.threshold, "Not enough balance");
        // ensures that orders queried shortly after one another result in the same hash (to avoid spamming the orderbook)
        // solhint-disable-next-line not-rely-on-time
        uint32 currentTimeBucket = ((uint32(block.timestamp) / 900) + 1) * 900;
        order = GPv2Order.Data(
            data.sellToken,
            data.buyToken,
            data.target,
            balance,
            1, // 0 buy amount is not allowed
            currentTimeBucket + 900, // between 15 and 30 miunte validity
            keccak256("TradeAboveThreshold"),
            0,
            GPv2Order.KIND_SELL,
            false,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }
}
