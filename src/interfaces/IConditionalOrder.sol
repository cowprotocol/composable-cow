// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {IERC165} from "safe/interfaces/IERC165.sol";

/// @title IConditionalOrder - Base interface for conditional orders
/// @author CoW Protocol Developers + mfw78 <mfw78@nxm.rs>
/// @notice Defines core order generation and settlement verification
interface IConditionalOrder {
    /// @notice Order condition permanently not met
    error OrderNotValid(string reason);

    /// @notice Condition not met, retry next block
    error PollTryNextBlock(string reason);

    /// @notice Condition not met, retry at timestamp
    error PollTryAtTimestamp(uint256 timestamp, string reason);

    /// @notice Condition not met, retry at block
    error PollTryAtBlock(uint256 blockNumber, string reason);

    /// @notice Parameters uniquely identifying a conditional order
    /// @dev H(handler || salt || staticInput) must be unique per owner
    struct ConditionalOrderParams {
        IConditionalOrder handler;
        bytes32 salt;
        bytes staticInput;
    }

    /// @notice Generate the discrete order for current conditions
    /// @dev Single source of truth for order logic. Used by both verify() and poll().
    /// @dev MUST revert with appropriate error if conditions not met.
    /// @param owner The Safe/wallet that owns this order
    /// @param sender The address initiating the call
    /// @param ctx Context key (bytes32(0) for merkle, hash(params) for single)
    /// @param staticInput Fixed order parameters (abi-encoded)
    /// @param offchainInput Dynamic parameters from watch-tower
    /// @return order The discrete order for CoW Protocol
    function generateOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) external view returns (GPv2Order.Data memory order);

    /// @notice Verify an order for settlement
    /// @dev Called via ComposableCoW during EIP-1271 signature verification.
    /// @dev MUST revert if order should not settle.
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata order
    ) external view;
}

/// @title IConditionalOrderGenerator - Extended interface with polling support
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Adds structured polling results for watch-tower integration
interface IConditionalOrderGenerator is IConditionalOrder, IERC165 {
    /// @notice Emitted when a conditional order is created with dispatch=true
    event ConditionalOrderCreated(address indexed owner, ConditionalOrderParams params);

    /// @notice Result codes for poll() calls
    enum PollResultCode {
        SUCCESS, // Order ready to trade
        PARTIALLY_FILLED, // Order partially filled, no action needed (informational)
        FILLED, // Order completely filled, no action needed
        WAIT_TIMESTAMP, // Wait for specific timestamp
        WAIT_BLOCK, // Wait for specific block
        TRY_NEXT_BLOCK, // Transient condition, retry next block
        INVALID // Permanently invalid, stop polling
    }

    /// @notice Structured result from poll()
    /// @dev Field validity depends on code - see docs/architecture.md
    struct PollResult {
        PollResultCode code;
        GPv2Order.Data order; // Valid when code == SUCCESS, PARTIALLY_FILLED, or FILLED
        uint256 nextPollTimestamp; // SUCCESS: when to poll for next order (0=validTo+1, max=never)
        uint256 waitUntil; // WAIT_*: timestamp or block to wait for
        string reason; // Human-readable status
        uint256 filledAmount; // PARTIALLY_FILLED/FILLED: amount that was filled
    }

    /// @notice Poll for a tradeable order with scheduling metadata
    /// @dev Called by watch-towers. Never reverts for order conditions.
    /// @dev Wraps generateOrder() with try/catch and adds polling hints.
    /// @return result Structured result with order (if ready) and scheduling hints
    function poll(address owner, address sender, bytes32 ctx, bytes calldata staticInput, bytes calldata offchainInput)
        external
        view
        returns (PollResult memory result);

    /// @notice Get scheduling hint for next poll after successful order
    /// @dev Only called by poll() after generateOrder() succeeds.
    /// @return nextPollTimestamp 0=use validTo+1, max=stop polling, other=poll at time
    function getNextPollTimestamp(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory order)
        external
        view
        returns (uint256 nextPollTimestamp);

    /// @notice Get human-readable order description
    /// @dev Only for off-chain UX, not called during settlement.
    function describeOrder(address owner, bytes32 ctx, bytes calldata staticInput, GPv2Order.Data memory order)
        external
        view
        returns (string memory description);
}
