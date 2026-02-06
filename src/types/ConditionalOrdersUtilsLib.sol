// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

/// @title ConditionalOrdersUtilsLib - Utility functions for standardising conditional orders
/// @author mfw78 <mfw78@nxm.rs>
library ConditionalOrdersUtilsLib {
    uint256 constant MAX_BPS = 10000;

    /// @notice Given the width of the validity bucket, return the timestamp of the *end* of the bucket.
    /// @param validity The width of the validity bucket in seconds.
    function validToBucket(uint32 validity) internal view returns (uint32 validTo) {
        // Calculate which bucket we're in, then return the end of that bucket
        uint32 currentBucket = uint32(block.timestamp) / validity;
        validTo = (currentBucket + 1) * validity;
    }

    /// @notice Scale a price from one decimal precision to another
    /// @param oraclePrice Price returned by a chainlink-like oracle
    /// @param fromDecimals The decimals the oracle returned (e.g. 8 for USDC)
    /// @param toDecimals The amount of decimals the price should be scaled to
    function scalePrice(int256 oraclePrice, uint8 fromDecimals, uint8 toDecimals) internal pure returns (int256) {
        if (fromDecimals < toDecimals) {
            return oraclePrice * int256(10 ** uint256(toDecimals - fromDecimals));
        } else if (fromDecimals > toDecimals) {
            return oraclePrice / int256(10 ** uint256(fromDecimals - toDecimals));
        }
        return oraclePrice;
    }
}
