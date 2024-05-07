// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {IWatchtowerCustomErrors} from "../interfaces/IWatchtowerCustomErrors.sol";

/**
 * @title ConditionalOrdersUtilsLib - Utility functions for standardising conditional orders.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
library ConditionalOrdersUtilsLib {
    uint256 constant MAX_BPS = 10000;

    /**
     * Given the width of the validity bucket, return the timestamp of the *end* of the bucket.
     * @param validity The width of the validity bucket in seconds.
     */
    function validToBucket(uint32 validity) internal view returns (uint32 validTo) {
        validTo = ((uint32(block.timestamp) / validity) * validity) + validity;
    }

    /**
     * Given a price returned by a chainlink-like oracle, scale it to the desired amount of decimals
     * @param oraclePrice return by a chainlink-like oracle
     * @param fromDecimals the decimals the oracle returned (e.g. 8 for USDC)
     * @param toDecimals the amount of decimals the price should be scaled to
     */
    function scalePrice(int256 oraclePrice, uint8 fromDecimals, uint8 toDecimals) internal pure returns (int256) {
        if (fromDecimals < toDecimals) {
            return oraclePrice * int256(10 ** uint256(toDecimals - fromDecimals));
        } else if (fromDecimals > toDecimals) {
            return oraclePrice / int256(10 ** uint256(fromDecimals - toDecimals));
        }
        return oraclePrice;
    }

    /**
     * @dev Reverts call execution with a custom error that indicates to the
     * watchtower to poll for new order when the next block is mined.
     */
    function revertPollAtNextBlock(string memory message) internal view {
        revert IWatchtowerCustomErrors.PollTryAtBlock(
            block.number + 1,
            message
        );
    }
}
