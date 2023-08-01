// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

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
}
