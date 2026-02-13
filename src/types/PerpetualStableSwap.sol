// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {
    IERC20,
    GPv2Order,
    IConditionalOrder,
    IConditionalOrderGenerator,
    BaseConditionalOrder
} from "../BaseConditionalOrder.sol";
import {IOrderManifest} from "../interfaces/IOrderManifest.sol";
import {ConditionalOrdersUtilsLib as Utils} from "./ConditionalOrdersUtilsLib.sol";

/// @title PerpetualStableSwap - 1:1 swaps between token pairs with spread
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Always willing to trade between tokenA and tokenB at 1:1 (adjusted for decimals) plus spread.
contract PerpetualStableSwap is BaseConditionalOrder {
    struct Data {
        IERC20 tokenA;
        IERC20 tokenB;
        uint32 validityBucketSeconds;
        uint256 halfSpreadBps;
        bytes32 appData;
    }

    struct BuySellData {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(address owner, address, bytes32, bytes calldata staticInput, bytes calldata)
        public
        view
        override
        returns (GPv2Order.Data memory order)
    {
        Data memory data = abi.decode(staticInput, (Data));

        BuySellData memory buySellData = side(owner, data);

        require(buySellData.sellAmount > 0, IConditionalOrder.OrderNotValid("not funded"));

        order = GPv2Order.Data(
            buySellData.sellToken,
            buySellData.buyToken,
            address(0),
            buySellData.sellAmount,
            buySellData.buyAmount,
            Utils.validToBucket(data.validityBucketSeconds),
            data.appData,
            0,
            GPv2Order.KIND_SELL,
            false,
            GPv2Order.BALANCE_ERC20,
            GPv2Order.BALANCE_ERC20
        );
    }

    /// @inheritdoc IConditionalOrderGenerator
    function describeOrder(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        pure
        override
        returns (string memory)
    {
        return "perpetual stable swap ready";
    }

    // ============ IOrderManifest Override (UNBOUNDED) ============

    /// @inheritdoc IOrderManifest
    /// @dev Perpetual orders have unbounded cardinality - they keep producing orders indefinitely
    function getManifestInfo(address, bytes32, bytes calldata)
        external
        pure
        override
        returns (ManifestInfo memory info)
    {
        info = ManifestInfo({cardinality: Cardinality.UNBOUNDED, totalOrders: 0});
    }

    /// @inheritdoc IOrderManifest
    /// @dev Returns current tradeable order with hasMore=true (always more orders possible)
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        uint256 offset,
        uint256 limit
    ) external view override returns (ManifestEntry[] memory entries, bool hasMore) {
        // For unbounded orders, we only return the current order at offset 0
        if (offset > 0 || limit == 0) {
            return (new ManifestEntry[](0), true); // hasMore is always true for unbounded
        }

        // Try to generate the current order
        try this.generateOrder(owner, address(0), ctx, staticInput, offchainInput) returns (
            GPv2Order.Data memory order
        ) {
            entries = new ManifestEntry[](1);
            entries[0] = ManifestEntry({
                index: 0, // Always 0 for unbounded (current order)
                order: order,
                validFrom: 0, // Valid immediately
                isActive: block.timestamp <= order.validTo
            });
            hasMore = true; // Perpetual orders always have more
        } catch {
            // If order generation fails (e.g., not funded), return empty but still hasMore
            return (new ManifestEntry[](0), true);
        }
    }

    // ============ Internal Functions ============

    function side(address owner, Data memory data) internal view returns (BuySellData memory buySellData) {
        IERC20 tokenA = IERC20(address(data.tokenA));
        IERC20 tokenB = IERC20(address(data.tokenB));
        uint256 balanceA = tokenA.balanceOf(owner);
        uint256 balanceB = tokenB.balanceOf(owner);

        if (convertAmount(tokenA, balanceA, tokenB) > balanceB) {
            buySellData = BuySellData({
                sellToken: tokenA,
                buyToken: tokenB,
                sellAmount: balanceA,
                buyAmount: convertAmount(tokenA, balanceA, tokenB) * (Utils.MAX_BPS + data.halfSpreadBps)
                    / Utils.MAX_BPS
            });
        } else {
            buySellData = BuySellData({
                sellToken: tokenB,
                buyToken: tokenA,
                sellAmount: balanceB,
                buyAmount: convertAmount(tokenB, balanceB, tokenA) * (Utils.MAX_BPS + data.halfSpreadBps)
                    / Utils.MAX_BPS
            });
        }
    }

    function convertAmount(IERC20 srcToken, uint256 srcAmount, IERC20 destToken)
        internal
        view
        returns (uint256 destAmount)
    {
        uint8 srcDecimals = srcToken.decimals();
        uint8 destDecimals = destToken.decimals();

        if (srcDecimals > destDecimals) {
            destAmount = srcAmount / (10 ** (srcDecimals - destDecimals));
        } else {
            destAmount = srcAmount * (10 ** (destDecimals - srcDecimals));
        }
    }
}
