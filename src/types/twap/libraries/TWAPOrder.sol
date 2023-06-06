// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, IERC20Metadata} from "@openzeppelin/interfaces/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";

import {TWAPOrderMathLib} from "./TWAPOrderMathLib.sol";

/**
 * @title Time-weighted Average Order Library
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Structs, errors, and functions for time-weighted average orders.
 */
library TWAPOrder {
    using SafeCast for uint256;

    // --- errors

    error InvalidSameToken();
    error InvalidToken();
    error InvalidPartSellAmount();
    error InvalidMinPartLimit();
    error InvalidStartTime();
    error InvalidNumParts();
    error InvalidFrequency();
    error InvalidSpan();

    // --- structs

    struct Data {
        IERC20 sellToken;
        IERC20 buyToken;
        address receiver;
        uint256 partSellAmount; // amount of sellToken to sell in each part
        uint256 minPartLimit; // max price to pay for a unit of buyToken denominated in sellToken
        uint256 t0;
        uint256 n;
        uint256 t;
        uint256 span;
        bytes32 appData;
    }

    // --- functions

    /**
     * @dev revert if the order is invalid
     * @param self The TWAP order to validate
     */
    function validate(Data memory self) internal pure {
        if (!(self.sellToken != self.buyToken)) revert InvalidSameToken();
        if (!(address(self.sellToken) != address(0) && address(self.buyToken) != address(0))) revert InvalidToken();
        if (!(self.partSellAmount > 0)) revert InvalidPartSellAmount();
        if (!(self.minPartLimit > 0)) revert InvalidMinPartLimit();
        if (!(self.t0 < type(uint32).max)) revert InvalidStartTime();
        if (!(self.n > 1 && self.n <= type(uint32).max)) revert InvalidNumParts();
        if (!(self.t > 0 && self.t <= 365 days)) revert InvalidFrequency();
        if (!(self.span <= self.t)) revert InvalidSpan();
    }

    /**
     * @dev Generate the `GPv2Order` for the current part of the TWAP order.
     * @param self The TWAP order to generate the order for.
     * @return order The `GPv2Order` for the current part.
     */
    function orderFor(Data memory self) internal view returns (GPv2Order.Data memory order) {
        // First, validate and revert if the TWAP is invalid.
        validate(self);

        // Calculate the `validTo` timestamp for the order. This is unique for each part of the TWAP order.
        // As `validTo` is unique, there is a corresponding unique `orderUid` for each `GPv2Order`. As
        // CoWProtocol enforces that each `orderUid` is only used once, this means that each part of the TWAP
        // order can only be executed once.
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
