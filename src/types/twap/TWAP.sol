// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ComposableCoW} from "../../ComposableCoW.sol";
import {
    IConditionalOrder,
    IConditionalOrderGenerator,
    GPv2Order,
    BaseConditionalOrder
} from "../../BaseConditionalOrder.sol";
import {IOrderManifest} from "../../interfaces/IOrderManifest.sol";
import {IERC165} from "../../interfaces/IConditionalOrder.sol";
import {TWAPOrder} from "./libraries/TWAPOrder.sol";
import {TWAPOrderMathLib, AFTER_TWAP_FINISH} from "./libraries/TWAPOrderMathLib.sol";

string constant NOT_WITHIN_SPAN = "outside span";

/// @title TWAP Conditional Order
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Splits an order into multiple parts executed at fixed intervals.
contract TWAP is BaseConditionalOrder {
    using SafeCast for uint256;

    ComposableCoW public immutable composableCow;

    constructor(ComposableCoW _composableCow) {
        composableCow = _composableCow;
    }

    // ============ Internal Helpers ============

    /// @dev Decode staticInput and resolve t0 from cabinet if needed
    function _resolveTwapData(address owner, bytes32 ctx, bytes calldata staticInput)
        internal
        view
        returns (TWAPOrder.Data memory twap)
    {
        twap = abi.decode(staticInput, (TWAPOrder.Data));
        if (twap.t0 == 0) {
            twap.t0 = uint256(composableCow.cabinet(owner, ctx));
        }
    }

    /// @dev Get the current part index from block.timestamp
    function _currentPart(TWAPOrder.Data memory twap) internal view returns (uint256) {
        return TWAPOrderMathLib.currentPart(twap.t0, twap.t);
    }

    /// @dev Calculate validFrom and validTo for any part index (pure, for manifest enumeration)
    /// @return validFrom The start timestamp for this part
    /// @return validTo The end timestamp for this part (inclusive)
    function _partTiming(TWAPOrder.Data memory twap, uint256 partIndex)
        internal
        pure
        returns (uint256 validFrom, uint256 validTo)
    {
        validFrom = twap.t0 + (partIndex * twap.t);

        if (twap.span == 0) {
            // Full epoch: valid until next part starts
            validTo = validFrom + twap.t - 1;
        } else {
            // Partial span within epoch
            validTo = validFrom + twap.span - 1;
        }
    }

    /// @dev Build GPv2Order.Data for any part index (pure, for manifest enumeration)
    /// @dev Does NOT check runtime conditions (before/after TWAP window). Use only for manifest.
    function _orderForPartPure(TWAPOrder.Data memory twap, uint256 partIndex)
        internal
        pure
        returns (GPv2Order.Data memory order)
    {
        (, uint256 validTo) = _partTiming(twap, partIndex);

        order = GPv2Order.Data({
            sellToken: twap.sellToken,
            buyToken: twap.buyToken,
            receiver: twap.receiver,
            sellAmount: twap.partSellAmount,
            buyAmount: twap.minPartLimit,
            validTo: validTo.toUint32(),
            appData: twap.appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    /// @dev Build a complete ManifestEntry for any part index
    function _manifestEntry(TWAPOrder.Data memory twap, uint256 partIndex)
        internal
        view
        returns (ManifestEntry memory entry)
    {
        (uint256 validFrom, uint256 validTo) = _partTiming(twap, partIndex);

        entry = ManifestEntry({
            index: partIndex,
            order: _orderForPartPure(twap, partIndex),
            validFrom: validFrom,
            isActive: block.timestamp >= validFrom && block.timestamp <= validTo
        });
    }

    // ============ IConditionalOrder Implementation ============

    /// @inheritdoc IConditionalOrder
    function generateOrder(address owner, address, bytes32 ctx, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);

        // Use TWAPOrder.orderFor which includes all runtime checks (before start, after finish)
        order = TWAPOrder.orderFor(twap);

        // Check if outside the TWAP part's span
        if (block.timestamp > order.validTo) {
            uint256 part = _currentPart(twap);
            uint256 nextPartStart = twap.t0 + ((part + 1) * twap.t);
            uint256 endTime = twap.t0 + (twap.n * twap.t);

            require(nextPartStart < endTime, IConditionalOrder.OrderNotValid(AFTER_TWAP_FINISH));
            revert IConditionalOrder.PollTryAtTimestamp(nextPartStart, NOT_WITHIN_SPAN);
        }
    }

    // ============ IConditionalOrderGenerator Implementation ============

    /// @inheritdoc IConditionalOrderGenerator
    function getNextPollTimestamp(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory)
        external
        view
        override
        returns (uint256)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);
        uint256 part = _currentPart(twap);

        // Last part - stop polling after this fills
        if (part >= twap.n - 1) {
            return POLL_NEVER;
        }

        // Next part starts at...
        return twap.t0 + ((part + 1) * twap.t);
    }

    /// @inheritdoc IConditionalOrderGenerator
    function describeOrder(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory)
        external
        view
        override
        returns (string memory)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);
        uint256 part = _currentPart(twap);

        if (part >= twap.n - 1) {
            return "final twap part";
        }
        return "twap part ready";
    }

    // ============ IOrderManifest Implementation ============

    /// @inheritdoc IOrderManifest
    function getManifestInfo(address owner, bytes32 ctx, bytes calldata staticInput)
        external
        view
        override
        returns (ManifestInfo memory info)
    {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);

        // TWAP always has exactly n parts
        info = ManifestInfo({cardinality: Cardinality.FINITE, totalOrders: twap.n});
    }

    /// @inheritdoc IOrderManifest
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata,
        uint256 offset,
        uint256 limit
    ) external view override returns (ManifestEntry[] memory entries, bool hasMore) {
        TWAPOrder.Data memory twap = _resolveTwapData(owner, ctx, staticInput);

        // If t0 is still 0 after resolution, the order hasn't been initialized
        if (twap.t0 == 0) {
            return (new ManifestEntry[](0), false);
        }

        // Validate order parameters
        try this.validateTwapData(twap) {}
        catch {
            return (new ManifestEntry[](0), false);
        }

        // Calculate pagination bounds
        uint256 totalParts = twap.n;
        if (offset >= totalParts) {
            return (new ManifestEntry[](0), false);
        }

        uint256 remaining = totalParts - offset;
        uint256 count = remaining < limit ? remaining : limit;
        hasMore = offset + count < totalParts;

        entries = new ManifestEntry[](count);
        for (uint256 i = 0; i < count; i++) {
            entries[i] = _manifestEntry(twap, offset + i);
        }
    }

    /// @dev External wrapper for validation (used with try/catch)
    function validateTwapData(TWAPOrder.Data memory twap) external pure {
        TWAPOrder.validate(twap);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return interfaceId == type(IConditionalOrderGenerator).interfaceId
            || interfaceId == type(IOrderManifest).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
