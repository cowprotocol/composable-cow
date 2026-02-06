// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20, GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {IConditionalOrder} from "../../../interfaces/IConditionalOrder.sol";
import {TWAPOrderMathLib} from "./TWAPOrderMathLib.sol";

string constant INVALID_SAME_TOKEN = "same token";
string constant INVALID_TOKEN = "invalid token";
string constant INVALID_PART_SELL_AMOUNT = "invalid part sell amount";
string constant INVALID_MIN_PART_LIMIT = "invalid min part limit";
string constant INVALID_START_TIME = "invalid start time";
string constant INVALID_NUM_PARTS = "invalid num parts";
string constant INVALID_FREQUENCY = "invalid frequency";
string constant INVALID_SPAN = "invalid span";

/// @title Time-weighted Average Order Library
/// @author mfw78 <mfw78@nxm.rs>
library TWAPOrder {
    using SafeCast for uint256;

    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 partSellAmount;
        uint256 minPartLimit;
        uint256 t0;
        uint256 n;
        uint256 t;
        uint256 span;
        bytes32 appData;
    }

    /// @dev Revert if the order is invalid
    function validate(Data memory self) internal pure {
        require(self.sellToken != self.buyToken, IConditionalOrder.OrderNotValid(INVALID_SAME_TOKEN));
        require(
            address(self.sellToken) != address(0) && address(self.buyToken) != address(0),
            IConditionalOrder.OrderNotValid(INVALID_TOKEN)
        );
        require(self.partSellAmount > 0, IConditionalOrder.OrderNotValid(INVALID_PART_SELL_AMOUNT));
        require(self.minPartLimit > 0, IConditionalOrder.OrderNotValid(INVALID_MIN_PART_LIMIT));
        require(self.t0 < type(uint32).max, IConditionalOrder.OrderNotValid(INVALID_START_TIME));
        require(self.n > 1 && self.n <= type(uint32).max, IConditionalOrder.OrderNotValid(INVALID_NUM_PARTS));
        require(self.t > 0 && self.t <= 365 days, IConditionalOrder.OrderNotValid(INVALID_FREQUENCY));
        require(self.span <= self.t, IConditionalOrder.OrderNotValid(INVALID_SPAN));
    }

    /// @dev Generate the `GPv2Order` for the current part of the TWAP order.
    function orderFor(Data memory self) internal view returns (GPv2Order.Data memory order) {
        validate(self);

        order = GPv2Order.Data({
            sellToken: self.sellToken,
            buyToken: self.buyToken,
            receiver: self.receiver,
            sellAmount: self.partSellAmount,
            buyAmount: self.minPartLimit,
            validTo: TWAPOrderMathLib.calculateValidTo(self.t0, self.n, self.t, self.span).toUint32(),
            appData: self.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}
