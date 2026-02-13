// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

/// @title IOrderManifest - Interface for order enumeration
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Allows enumeration of all discrete orders that a conditional order will produce.
/// @dev Useful for analytics, UI preview, and order lifecycle tracking.
interface IOrderManifest {
    /// @notice Describes the cardinality of orders produced by a conditional order
    enum Cardinality {
        FINITE, // Known fixed number of orders (e.g., TWAP with n parts)
        BOUNDED, // Upper bound known, actual count is dynamic
        UNBOUNDED // Potentially infinite orders (e.g., PerpetualStableSwap)
    }

    /// @notice High-level information about the order manifest
    /// @param cardinality The cardinality type of this conditional order
    /// @param totalOrders Exact count for FINITE, max for BOUNDED, 0 for UNBOUNDED
    struct ManifestInfo {
        Cardinality cardinality;
        uint256 totalOrders;
    }

    /// @notice A single entry in the manifest representing one discrete order
    /// @param index The index of this order (0-indexed)
    /// @param order The GPv2Order data for this discrete order
    /// @param validFrom When this order becomes valid (since GPv2Order only has validTo)
    /// @param isActive Whether this order is currently active (within its validity window)
    struct ManifestEntry {
        uint256 index;
        GPv2Order.Data order;
        uint256 validFrom;
        bool isActive;
    }

    /// @notice Get high-level information about the order manifest
    /// @dev Returns cardinality and total order count for this conditional order.
    /// @param owner The owner of the conditional order
    /// @param ctx Context key (bytes32(0) for merkle, hash(params) for single)
    /// @param staticInput The static input parameters for the conditional order
    /// @return info The manifest information
    function getManifestInfo(address owner, bytes32 ctx, bytes calldata staticInput)
        external
        view
        returns (ManifestInfo memory info);

    /// @notice Get a paginated list of manifest entries
    /// @dev For FINITE orders, returns all orders within pagination bounds.
    ///      For UNBOUNDED orders, returns current tradeable order with hasMore=true.
    /// @param owner The owner of the conditional order
    /// @param ctx Context key (bytes32(0) for merkle, hash(params) for single)
    /// @param staticInput The static input parameters for the conditional order
    /// @param offchainInput Dynamic parameters from watch-tower (may be empty)
    /// @param offset Starting index for pagination
    /// @param limit Maximum number of entries to return
    /// @return entries Array of manifest entries
    /// @return hasMore Whether more entries exist beyond this page
    function getManifestPage(
        address owner,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        uint256 offset,
        uint256 limit
    ) external view returns (ManifestEntry[] memory entries, bool hasMore);
}
