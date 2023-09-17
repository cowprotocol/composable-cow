# Time-weighted average price (TWAP)

A simple _time-weighted average price_ trade may be thought of as `n` smaller trades happening every `t` time interval, commencing at time `t0`. Additionally, it is possible to limit a part's validity of the order to a certain `span` of time interval `t`.

## Data Structure

```solidity=
struct Data {
    IERC20 sellToken;
    IERC20 buyToken;
    address receiver; // address(0) if the safe
    uint256 partSellAmount; // amount to sell in each part
    uint256 minPartLimit; // minimum buy amount in each part (limit)
    uint256 t0;
    uint256 n;
    uint256 t;
    uint256 span;
    bytes32 appData;
}
```

**NOTE:** No direction of trade is specified, as for TWAP it is assumed to be a _sell_ order

Example: Alice wants to sell 12,000,000 DAI for at least 7500 WETH. She wants to do this using a TWAP, executing a part each day over a period of 30 days.

- `sellToken` = DAI
- `buytoken` = WETH
- `receiver` = `address(0)`
- `partSellAmount` = 12000000 / 30 = 400000 DAI
- `minPartLimit` = 7500 / 30 = 250 WETH
- `t0` = Nominated start time (unix epoch seconds)
- `n` = 30 (number of parts)
- `t` = 86400 (duration of each part, in seconds)
- `span` = 0 (duration of `span`, in seconds, or `0` for entire interval)

If Alice also wanted to restrict the duration in which each part traded in each day, she may set `span` to a non-zero duration. For example, if Alice wanted to execute the TWAP, each day for 30 days, however only wanted to trade for the first 12 hours of each day, she would set `span` to `43200` (ie. `60 * 60 * 12`).

Using `span` allows for use cases such as weekend or week-day only trading.

## Methodology

To create a TWAP order:

1. ABI-Encode the `IConditionalOrder.ConditionalOrderParams` struct with:
   - `handler`: set to the `TWAP` smart contract deployment.
   - `salt`: set to a unique value.
   - `staticInput`: the ABI-encoded `TWAP.Data` struct.
2. Use the `struct` from (1) as either a Merkle leaf, or with `ComposableCoW.create` to create a single conditional order.
3. Approve `GPv2VaultRelayer` to trade `n x partSellAmount` of the safe's `sellToken` tokens (in the example above, `GPv2VaultRelayer` would receive approval for spending 12,000,000 DAI tokens).

**NOTE**: When calling `ComposableCoW.create`, setting `dispatch = true` will cause `ComposableCoW` to emit event logs that are indexed by the watch tower automatically. If you wish to maintain a private order (and will submit to the CoW Protocol API through your own infrastructure, you may set `dispatch` to `false`).

Fortunately, when using Safe, it is possible to batch together all the above calls to perform this step atomically, and optimise gas consumption / UX.

**NOTE:** For cancelling a TWAP order, follow the instructions at [Conditional order cancellation](../../README.md#conditional-order-cancellation).
