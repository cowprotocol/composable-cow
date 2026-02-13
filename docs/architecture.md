# Composable CoW Architecture

## Overview

Composable CoW is a framework for creating conditional orders on CoW Protocol. It enables any wallet capable of ERC-1271 signatures to define orders that become tradeable when specific conditions are met (price thresholds, time windows, balance triggers, and so forth).

ERC-1271 is the standard for smart contract signature verification, allowing contracts to validate signatures on behalf of their owners. This includes Safe wallets, Argent, Sequence, and other smart contract wallets.

The architecture separates two distinct execution paths:

1. **Settlement Path** — on-chain verification during trade execution (gas-sensitive).
2. **Polling Path** — off-chain queries by watch-towers (gas-irrelevant).

This separation ensures settlement remains gas-efficient while providing rich metadata for off-chain infrastructure.

## Design Principles

1. **Single source of truth**: `generateOrder()` contains all order generation logic.
2. **Lean settlement**: No metadata structs; only constant string errors for debugging.
3. **Rich polling**: Structured results with scheduling hints for watch-towers.
4. **No code duplication**: Polling wraps the same core logic used by settlement.

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

IOrderManifest
├── Cardinality enum (FINITE, BOUNDED, UNBOUNDED)
├── ManifestInfo struct (cardinality, totalOrders)
├── ManifestEntry struct (index, order, validFrom, isActive)
├── getManifestInfo() - order cardinality info
└── getManifestPage() - paginated order enumeration
```

## Execution Paths

### Settlement Path (On-Chain)

```
CoW Settlement
    │
    ▼
Wallet.isValidSignature(hash, signature)    ERC-1271 verification
    │
    ▼
[Wallet-specific routing]                   e.g., Safe's ExtensibleFallbackHandler
    │
    ▼
ComposableCoW.isValidSafeSignature(...)     Signature validation
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

**Note**: The function `isValidSafeSignature` works with any ERC-1271-compatible wallet that routes signature verification to ComposableCoW. The name reflects the original Safe integration, but the interface is wallet-agnostic.

**Gas considerations**:
- Error reasons use constant strings (minimal allocation).
- No `PollResult` construction.
- No polling metadata calls.
- Minimal computation beyond core validation.

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
- Returns structured `PollResult`; never reverts for order conditions.
- Includes scheduling hints (`nextPollTimestamp` and `waitUntil`).
- Provides human-readable reasons for debugging.
- Checks GPv2Settlement for fill status before building the signature.

## Error Types

Errors include string reasons for debugging. Using constant strings (e.g., `INVALID_HASH` and `BEFORE_TWAP_START`) minimizes gas overhead while improving debuggability:

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
| `PARTIALLY_FILLED` | Order partially filled | No action; informational only |
| `FILLED` | Order completely filled | No action; informational only |
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

## Order Manifest Interface

The `IOrderManifest` interface enables enumeration of all discrete orders that a conditional order will produce. This is useful for analytics, UI previews, and order lifecycle tracking.

### Cardinality Types

| Cardinality | Description | Example |
|-------------|-------------|---------|
| `FINITE` | Known fixed number of orders | TWAP with n parts |
| `BOUNDED` | Upper bound known; actual count is dynamic | Future order types |
| `UNBOUNDED` | Potentially infinite orders | PerpetualStableSwap |

### ManifestInfo Structure

```solidity
struct ManifestInfo {
    Cardinality cardinality;
    uint256 totalOrders;  // Exact for FINITE, max for BOUNDED, 0 for UNBOUNDED
}
```

### ManifestEntry Structure

```solidity
struct ManifestEntry {
    uint256 index;           // Order index (0-indexed)
    GPv2Order.Data order;    // The discrete order
    uint256 validFrom;       // When this order becomes valid
    bool isActive;           // Whether currently within validity window
}
```

The `validFrom` field is needed because `GPv2Order.Data` only contains `validTo`.

### Manifest Implementation by Order Type

| Order Type | Cardinality | totalOrders | Behavior |
|------------|-------------|-------------|----------|
| TWAP | FINITE | n (number of parts) | Returns all n parts with timing |
| StopLoss | FINITE | 1 | Single order from generateOrder() |
| GoodAfterTime | FINITE | 1 | Single order from generateOrder() |
| TradeAboveThreshold | FINITE | 1 | Single order from generateOrder() |
| PerpetualStableSwap | UNBOUNDED | 0 | Current order, hasMore=true |

### Default Implementation

`BaseConditionalOrder` provides a default manifest implementation for single-shot orders:
- `getManifestInfo()` returns `FINITE` with `totalOrders: 1`.
- `getManifestPage()` wraps `generateOrder()` for a single entry.

## ComposableCoW Contract

### Events

| Event | Description |
|-------|-------------|
| `MerkleRootSet(address indexed owner, bytes32 root, Proof proof)` | Merkle root updated |
| `ConditionalOrderCreated(address indexed owner, ConditionalOrderParams params)` | Order created with dispatch=true |
| `ConditionalOrderRemoved(address indexed owner, bytes32 indexed orderHash)` | Order deauthorized |
| `SwapGuardSet(address indexed owner, ISwapGuard swapGuard)` | Swap guard updated |

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

The `_auth()` function verifies authorization and returns the context key as follows:
- Merkle orders: `ctx = bytes32(0)`.
- Single orders: `ctx = hash(params)`.

### Context Storage (Cabinet)

The `cabinet` mapping stores per-order context:
```solidity
mapping(address owner => mapping(bytes32 ctx => bytes32 value)) public cabinet;
```

This is used by TWAP to store dynamic start times set at order creation.

## ERC-1271 Integration

ComposableCoW is designed to work with any smart contract wallet that implements ERC-1271 (`isValidSignature`). The integration requires the wallet to route signature verification requests to ComposableCoW.

### How It Works

1. **Order Creation**: The wallet owner authorizes conditional orders via `create()` or `setRoot()`.
2. **Signature Verification**: When CoW Protocol settlement calls `isValidSignature(hash, signature)` on the wallet, it routes the call to ComposableCoW.
3. **Validation**: ComposableCoW verifies authorization and validates the order via `generateOrder()`.

### Supported Wallets

| Wallet Type | Integration Method |
|-------------|-------------------|
| Safe | ExtensibleFallbackHandler with domain verifier |
| Other ERC-1271 | Extend `ERC1271Forwarder` abstract contract |

### ERC1271Forwarder

The `ERC1271Forwarder` abstract contract provides a ready-made integration for any ERC-1271 wallet. Extend this contract to add ComposableCoW support:

```solidity
import {ERC1271Forwarder} from "./ERC1271Forwarder.sol";

contract MyWallet is ERC1271Forwarder {
    constructor(ComposableCoW _composableCoW) ERC1271Forwarder(_composableCoW) {}
    // ... wallet implementation
}
```

The forwarder:
1. Receives `isValidSignature(bytes32 _hash, bytes signature)` calls.
2. Decodes the signature as `(GPv2Order.Data, ComposableCoW.PayloadStruct)`.
3. Verifies that the order hash matches the provided hash.
4. Forwards the request to `ComposableCoW.isValidSafeSignature()` for order validation.

### Custom Integration

For wallets that cannot extend `ERC1271Forwarder`, implement the forwarding manually:

1. Decode the signature to extract `GPv2Order.Data` and `ComposableCoW.PayloadStruct`.
2. Verify that `GPv2Order.hash(order, domainSeparator) == _hash`.
3. Call `composableCoW.isValidSafeSignature(owner, sender, hash, domainSeparator, typeHash, encodedOrder, encodedPayload)`.

## Implementation Checklist for New Order Types

1. Extend `BaseConditionalOrder`.
2. Implement `generateOrder()`:
   - Validate conditions using `require(condition, CustomError(reason))`.
   - Use constant string reasons (e.g., `string constant MY_ERROR = "my error"`).
   - Build and return `GPv2Order.Data`.
3. Override `getNextPollTimestamp()` if not using the default:
   - Return `0` for 'use validTo + 1'.
   - Return `type(uint256).max` for single-shot orders.
   - Return a specific timestamp for multi-part orders.
4. Optionally override `describeOrder()` for better UX.
5. Override manifest functions if not single-shot:
   - `getManifestInfo()` — return appropriate cardinality.
   - `getManifestPage()` — implement pagination for multi-part orders.
   - For UNBOUNDED orders, always return `hasMore=true`.

## Gas Comparison

| Operation | Settlement Path | Polling Path |
|-----------|----------------|--------------|
| `generateOrder()` | Yes | Yes |
| Hash verification | Yes | No |
| `getNextPollTimestamp()` | No | Yes |
| `describeOrder()` | No | Yes |
| Error reason strings | Yes (constants) | Yes (constants) |
| PollResult construction | No | Yes |

The settlement path executes only what is necessary for validation. Error reason strings use compile-time constants to minimize gas overhead while providing useful debugging information.

## Breaking Changes from Upstream

This fork introduces significant architectural changes from [cowprotocol/composable-cow](https://github.com/cowprotocol/composable-cow). The following sections document all breaking changes for migration purposes.

### IConditionalOrder Interface

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Error renamed | `PollTryAtEpoch(uint256, string)` | `PollTryAtTimestamp(uint256, string)` |
| Error removed | `PollNever(string)` | Use `PollResultCode.INVALID` instead |
| Function added | - | `generateOrder()` (moved from IConditionalOrderGenerator) |

**Migration**: Replace `PollTryAtEpoch` with `PollTryAtTimestamp`, and replace `revert PollNever(reason)` with `revert OrderNotValid(reason)`.

### IConditionalOrderGenerator Interface

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Function removed | `getTradeableOrder()` | Use `generateOrder()` (in base interface) |
| Struct added | - | `PollResult` |
| Enum added | - | `PollResultCode` |
| Function added | - | `poll()` returning `PollResult` |
| Function added | - | `getNextPollTimestamp()` |
| Function added | - | `describeOrder()` |

**Migration**: Rename `getTradeableOrder()` to `generateOrder()`, and implement `getNextPollTimestamp()` and `describeOrder()` (or use the defaults from `BaseConditionalOrder`).

### ComposableCoW Contract

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Return type changed | `getTradeableOrderWithSignature() returns (GPv2Order.Data, bytes)` | `getTradeableOrderWithSignature() returns (PollResult, bytes)` |
| Function added | - | `checkOrder() returns (PollResultCode, uint256)` |
| Event added | - | `ConditionalOrderRemoved(address indexed, bytes32 indexed)` |
| State added | - | `settlement` (CoWSettlement immutable) |
| Feature added | - | Fill status checking via `GPv2Settlement.filledAmount()` |

**Migration**: Update callers of `getTradeableOrderWithSignature()` to handle the `PollResult` struct instead of the raw `GPv2Order.Data`. The order is now in `result.order`, and `result.code` indicates the status.

```solidity
// Upstream
(GPv2Order.Data memory order, bytes memory sig) = composableCow.getTradeableOrderWithSignature(...);

// This fork
(IConditionalOrderGenerator.PollResult memory result, bytes memory sig) = composableCow.getTradeableOrderWithSignature(...);
if (result.code == IConditionalOrderGenerator.PollResultCode.SUCCESS) {
    GPv2Order.Data memory order = result.order;
    // ... submit order
}
```

### BaseConditionalOrder

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Function renamed | `getTradeableOrder()` (abstract) | `generateOrder()` (abstract) |
| Function added | - | `poll()` (concrete implementation) |
| Function added | - | `getNextPollTimestamp()` (virtual, default: 0) |
| Function added | - | `describeOrder()` (virtual, default: "order ready") |
| Interface added | - | Implements `IOrderManifest` |
| Function added | - | `getManifestInfo()` (virtual, default: FINITE/1) |
| Function added | - | `getManifestPage()` (virtual, default: single entry) |
| Constant added | - | `POLL_AT_VALIDTO = 0` |
| Constant added | - | `POLL_NEVER = type(uint256).max` |

**Migration**: Rename `getTradeableOrder()` to `generateOrder()`. The base class now provides a `poll()` implementation that wraps `generateOrder()` with try/catch.

### New Interface: IOrderManifest

This interface is entirely new and provides order enumeration capabilities:

```solidity
interface IOrderManifest {
    enum Cardinality { FINITE, BOUNDED, UNBOUNDED }
    struct ManifestInfo { Cardinality cardinality; uint256 totalOrders; }
    struct ManifestEntry { uint256 index; GPv2Order.Data order; uint256 validFrom; bool isActive; }

    function getManifestInfo(...) external view returns (ManifestInfo memory);
    function getManifestPage(...) external view returns (ManifestEntry[] memory, bool hasMore);
}
```

**Migration**: No action is required for existing order types if extending `BaseConditionalOrder` (which provides a default single-shot implementation). Override for multi-part orders such as TWAP.

### Vendored CoWSettlement Interface

| Change | Upstream | This Fork |
|--------|----------|-----------|
| Function added | - | `filledAmount(bytes orderUid) returns (uint256)` |

This addition enables the framework to check fill status and return `PARTIALLY_FILLED` or `FILLED` poll result codes accordingly.

### Summary of Function Renames

| Upstream | This Fork |
|----------|-----------|
| `getTradeableOrder()` | `generateOrder()` |
| `PollTryAtEpoch` | `PollTryAtTimestamp` |

### Summary of Removed Items

| Item | Replacement |
|------|-------------|
| `PollNever` error | `OrderNotValid` error or `PollResultCode.INVALID` |
| `GPv2Interaction` import | Removed (unused) |
