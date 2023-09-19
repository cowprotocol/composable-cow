// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IConditionalOrder} from "../../../interfaces/IConditionalOrder.sol";

// --- error strings

/// @dev No discrete order is valid before the start of the TWAP conditional order.
string constant BEFORE_TWAP_START = "before twap start";
/// @dev No discrete order is valid after it's last part.
string constant AFTER_TWAP_FINISH = "after twap finish";

/**
 * @title CoWProtocol TWAP Order Math Library
 * @dev TWAP Math is separated to facilitate easier unit testing / SMT verification.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
library TWAPOrderMathLib {
    /**
     * @dev Calculate the `validTo` timestamp for part of a TWAP order.
     * @param startTime The start time of the TWAP order.
     * @param numParts The number of parts to split the order into.
     * @param frequency The frequency of each part (in seconds).
     * @param span The span of each part (in seconds, or 0 for the whole epoch).
     */
    function calculateValidTo(uint256 startTime, uint256 numParts, uint256 frequency, uint256 span)
        internal
        view
        returns (uint256 validTo)
    {
        /**
         * @dev Use `assert` to check for invalid inputs as these should be caught by the
         * conditional order validation logic in `dispatch` before calling this function.
         * This is to save on gas deployment costs vs using `require` statements.
         */
        assert(numParts > 1 && numParts <= type(uint32).max);
        assert(frequency > 0 && frequency <= 365 days);
        assert(span <= frequency);

        unchecked {
            /// @dev Order is not valid before the start (order commences at `t0`).
            if (!(startTime <= block.timestamp)) revert IConditionalOrder.PollTryAtEpoch(startTime, BEFORE_TWAP_START);

            /**
             *  @dev Order is expired after the last part (`n` parts, running at `t` time length).
             *
             * Multiplication overflow: `numParts` is bounded by `type(uint32).max` and `frequency` is bounded by
             * `365 days` which is smaller than `type(uint32).max` so the product of `numParts * frequency` is
             * ≈ 2⁵⁴.
             * Addition overflow: `startTime` is bounded by `block.timestamp` which is reasonably bounded by
             * `type(uint32).max` so the sum of `startTime + (numParts * frequency)` is ≈ 2⁵⁵.
             */
            if (!(block.timestamp < startTime + (numParts * frequency))) {
                revert IConditionalOrder.PollNever(AFTER_TWAP_FINISH);
            }

            /**
             * @dev We use integer division to get the part number as we want to round down to the nearest part.
             *
             * Subtraction underflow: `startTime` is asserted to be less than `block.timestamp` so the difference
             * of `block.timestamp - startTime` shall always be positive.
             * Divide by zero: `frequency` is asserted to be greater than zero.
             */
            uint256 part = (block.timestamp - startTime) / frequency;
            // calculate the `validTo` timestamp (inclusive as per `GPv2Order`)
            if (span == 0) {
                /**
                 * @dev If the span is zero, then the order is valid for the entire part.
                 *      We can safely add `part + 1` to `part` as we know that `part` is less than `numParts`.
                 *
                 * Addition overflow: `part` is bounded by `numParts` which is bounded by `type(uint32).max` so
                 * the sum of `part + 1` is ≈ 2³².
                 * Multiplication overflow: `frequency` is bounded by `365 days` which is smaller than
                 * `type(uint32).max` so the product of `frequency * (part + 1)` is ≈ 2⁵⁴.
                 * Addition overflow: `startTime` is bounded by `block.timestamp` which is reasonably bounded by
                 * `type(uint32).max` so the sum of `startTime + (frequency * (part + 1))` is ≈ 2⁵⁵.
                 * Subtraction underflow: `frequency` is asserted to be > 0 so `(frequency * (part + 1)) - 1` > 0
                 * where `part` ∈ N ∪ {0}. As `part` will always be at least 0, the difference of
                 * `startTime + (frequency * (part + 1)) - 1` shall always be positive.
                 */
                return startTime + ((part + 1) * frequency) - 1;
            }

            /**
             *  @dev If the span is non-zero, then the order is valid for the span of the part.
             *
             * Multiplication overflow: `part` is bounded by `numParts` which is bounded by `type(uint32).max` with
             * `frequency` bounded by `365 days` which is smaller than `type(uint32).max` so the product of
             * `part * frequency` is ≈ 2⁵⁴.
             * Addition overflow: `startTime` is bounded by `block.timestamp` which is reasonably bounded by
             * `type(uint32).max` so the sum of `startTime + (part * frequency)` is ≈ 2⁵⁵.
             * Addition overflow: `span` is bounded by `frequency` which is bounded by `365 days` which is smaller
             * than `type(uint32).max` so the sum of `(part * frequency) + span` is ≈ 2⁵⁶.
             * Subtraction underflow: `span` is asserted to be greater than zero so `(part * frequency) + span - 1`
             * shall always be positive.
             */
            validTo = startTime + (part * frequency) + span - 1;

            /**
             * @dev Order is not valid if not within nominated span. This doesn't need to be asserted as it is
             * checked during settlement in `GPv2Settlement.settle`.
             */
        }
    }
}
