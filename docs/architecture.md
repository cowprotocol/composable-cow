# Composable CoW Architecture

## Overview

Composable CoW is a framework for creating conditional orders on CoW Protocol. It enables Safe wallets to define orders that become tradeable when specific conditions are met (price thresholds, time windows, balance triggers, etc.).

The architecture separates two distinct execution paths:

1. **Settlement Path** - On-chain verification during trade execution (gas-sensitive)
2. **Polling Path** - Off-chain queries by watch-towers (gas-irrelevant)

This separation ensures settlement remains gas-efficient while providing rich metadata for off-chain infrastructure.

## Design Principles

1. **Single source of truth**: `generateOrder()` contains all order generation logic
2. **Lean settlement**: No metadata structs, only constant string errors for debugging
3. **Rich polling**: Structured results with scheduling hints for watch-towers
4. **No code duplication**: Polling wraps the same core logic used by settlement

## Interface Hierarchy

```
IConditionalOrder
├── Errors (with string reasons for debugging)
│   ├── OrderNotValid(string reason)
│   ├── PollTryNextBlock(string reason)
│   ├── PollTryAtTimestamp(uint256 timestamp, string reason)
│   └── PollTryAtBlock(uint256 blockNumber, string reason)
├── ConditionalOrderParams struct
├── generateOrder() - core order generation
└── verify() - settlement validation

IConditionalOrderGenerator : IConditionalOrder, IERC165
├── PollResultCode enum
├── PollResult struct
├── poll() - rich polling with metadata
├── getNextPollTimestamp() - scheduling hints
└── describeOrder() - human-readable status
```

## Execution Paths

### Settlement Path (On-Chain)

```
CoW Settlement
    │
    ▼
Safe.isValidSignature(hash, signature)
    │
    ▼
ExtensibleFallbackHandler
    │
    ▼
ComposableCoW.isValidSafeSignature(...)
    │
    ├── _auth()                     Verify merkle proof or single order
    ├── _guardCheck()               Optional swap guard
    │
    └── handler.verify(...)         LEAN PATH
              │
              ▼
        generateOrder()             Core logic, reverts if invalid
              │
              └── hash check        Verify order matches
```

**Gas considerations**:
- Error reasons use constant strings (minimal allocation)
- No PollResult construction
- No polling metadata calls
- Minimal computation beyond core validation

### Polling Path (Off-Chain)

```
Watch-Tower
    │
    ▼
ComposableCoW.getTradeableOrderWithSignature(...)
    │
    ├── _auth()                     Verify authorization
    │
    └── handler.poll(...)           RICH PATH
              │
              ▼
        try generateOrder()         Same core logic
              │
              ├── Success:
              │   ├── getNextPollTimestamp()
              │   ├── describeOrder()
              │   └── return PollResult(SUCCESS, order, hints)
              │
              └── Revert:
                  ├── decode error selector
                  └── return PollResult(WAIT_*, waitUntil, reason)
    │
    ▼ (on SUCCESS)
_getFilledAmount()                  Check GPv2Settlement
    │
    ├── filledAmount >= totalAmount:
    │   └── return PollResult(FILLED, order, filledAmount)
    │
    ├── filledAmount > 0:
    │   └── return PollResult(PARTIALLY_FILLED, order, filledAmount)
    │
    └── filledAmount == 0:
        ├── _guardCheck()           Optional swap guard
        └── _buildSignature()       Build EIP-1271 signature
```

**Characteristics**:
- Returns structured `PollResult`, never reverts for order conditions
- Includes scheduling hints (`nextPollTimestamp`, `waitUntil`)
- Human-readable reasons for debugging
- Checks GPv2Settlement for fill status before building signature

## Error Types

Errors include string reasons for debugging. Using constant strings (e.g., `INVALID_HASH`, `BEFORE_TWAP_START`) minimizes gas overhead while improving debuggability:

| Error | Meaning | Watch-tower Action |
|-------|---------|-------------------|
| `OrderNotValid(string)` | Permanent failure | Stop polling |
| `PollTryNextBlock(string)` | Transient, retry soon | Poll next block |
| `PollTryAtTimestamp(uint256, string)` | Wait for time | Schedule at timestamp |
| `PollTryAtBlock(uint256, string)` | Wait for block | Schedule at block |

## PollResult Structure

```solidity
enum PollResultCode {
    SUCCESS,          // Order ready to trade
    PARTIALLY_FILLED, // Order partially filled, no action needed (informational)
    FILLED,           // Order completely filled, no action needed
    WAIT_TIMESTAMP,   // Not ready, wait for timestamp
    WAIT_BLOCK,       // Not ready, wait for block
    TRY_NEXT_BLOCK,   // Not ready, transient condition
    INVALID           // Permanently invalid, stop polling
}

struct PollResult {
    PollResultCode code;
    GPv2Order.Data order;        // Valid when SUCCESS, PARTIALLY_FILLED, or FILLED
    uint256 nextPollTimestamp;   // When to poll for next order
    uint256 waitUntil;           // For WAIT_*: when to retry
    string reason;               // Human-readable (off-chain only)
    uint256 filledAmount;        // PARTIALLY_FILLED/FILLED: amount filled
}
```

### PollResultCode Semantics

| Code | Meaning | Watch-tower Action |
|------|---------|-------------------|
| `SUCCESS` | Order ready to trade | Submit to CoW Protocol API |
| `PARTIALLY_FILLED` | Order partially filled | No action, informational only |
| `FILLED` | Order completely filled | No action, informational only |
| `WAIT_TIMESTAMP` | Wait for specific time | Schedule poll at `waitUntil` |
| `WAIT_BLOCK` | Wait for specific block | Schedule poll at block `waitUntil` |
| `TRY_NEXT_BLOCK` | Transient condition | Poll again next block |
| `INVALID` | Permanently invalid | Stop polling this order |

### nextPollTimestamp Semantics

| Value | Meaning |
|-------|---------|
| `0` | Use `order.validTo + 1` as default |
| `> 0` | Poll at this specific timestamp |
| `type(uint256).max` | Final order, stop polling after fill |

## Order Type Patterns

### Single-Shot Orders (StopLoss, GoodAfterTime)

```solidity
function generateOrder(...) public view returns (GPv2Order.Data memory) {
    // Validate conditions - use require with custom errors (Solidity 0.8.30+)
    require(!expired, OrderNotValid("order expired"));
    require(conditionMet, PollTryNextBlock("condition not met"));

    // Build and return order
    return GPv2Order.Data(...);
}

function getNextPollTimestamp(...) external pure returns (uint256) {
    return type(uint256).max;  // POLL_NEVER - single shot
}
```

### Multi-Part Orders (TWAP)

```solidity
function generateOrder(...) public view returns (GPv2Order.Data memory) {
    require(block.timestamp >= startTime, PollTryAtTimestamp(startTime, "before twap start"));
    require(block.timestamp < endTime, OrderNotValid("twap finished"));

    // Calculate current part and build order
    return buildPartOrder(currentPart);
}

function getNextPollTimestamp(...) external view returns (uint256) {
    uint256 currentPart = calculateCurrentPart();
    if (currentPart == lastPart) return type(uint256).max;
    return startTime + ((currentPart + 1) * frequency);
}
```

### Perpetual Orders (PerpetualStableSwap)

```solidity
function generateOrder(...) public view returns (GPv2Order.Data memory) {
    require(funded, OrderNotValid("not funded"));
    return GPv2Order.Data(...);
}

function getNextPollTimestamp(...) external pure returns (uint256) {
    return 0;  // Use validTo + 1, perpetually repeating
}
```

## ComposableCoW Contract

### Key Functions

| Function | Path | Returns |
|----------|------|---------|
| `isValidSafeSignature()` | Settlement | `bytes4` magic value |
| `getTradeableOrderWithSignature()` | Polling | `(PollResult, signature)` |
| `checkOrder()` | Polling | `(PollResultCode, waitUntil)` |

### Authorization

Orders are authorized via:
- **Single orders**: `singleOrders[owner][hash(params)] = true`
- **Merkle roots**: `roots[owner] = merkleRoot`

The `_auth()` function verifies authorization and returns the context key:
- Merkle orders: `ctx = bytes32(0)`
- Single orders: `ctx = hash(params)`

### Context Storage (Cabinet)

The `cabinet` mapping stores per-order context:
```solidity
mapping(address owner => mapping(bytes32 ctx => bytes32 value)) public cabinet;
```

Used by TWAP to store dynamic start times set at order creation.

## Implementation Checklist for New Order Types

1. Extend `BaseConditionalOrder`
2. Implement `generateOrder()`:
   - Validate conditions using `require(condition, CustomError(reason))`
   - Use constant string reasons (e.g., `string constant MY_ERROR = "my error"`)
   - Build and return `GPv2Order.Data`
3. Override `getNextPollTimestamp()` if not using default:
   - Return `0` for "use validTo + 1"
   - Return `type(uint256).max` for single-shot orders
   - Return specific timestamp for multi-part orders
4. Optionally override `describeOrder()` for better UX

## Gas Comparison

| Operation | Settlement Path | Polling Path |
|-----------|----------------|--------------|
| `generateOrder()` | Yes | Yes |
| Hash verification | Yes | No |
| `getNextPollTimestamp()` | No | Yes |
| `describeOrder()` | No | Yes |
| Error reason strings | Yes (constants) | Yes (constants) |
| PollResult construction | No | Yes |

The settlement path only executes what's necessary for validation. Error reason strings use compile-time constants to minimize gas overhead while providing useful debugging information.
