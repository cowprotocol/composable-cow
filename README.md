# `ComposableCoW`: Composable Conditional orders

This repository is the next in evolution of the [`conditional-smart-orders`](https://github.com/cowprotocol/conditional-smart-orders), providing a unified interface for stateless, composable conditional orders. `ComposableCoW` is designed to be used with the [`ExtensibleFallbackHandler`](https://github.com/rndlabs/safe-contracts/tree/merged-efh-sigmuxer), a powerful _extensible_ fallback handler that allows for significant customisation of a `Safe`, while preserving strong security guarantees.

## Architecture

A detailed explanation on the architecture is available [here](https://hackmd.io/@mfw78/ByFP7Iazn).

### Methodology

For the purposes of outlining the methodologies, it is assumed that:

1. The `Safe` has already had its fallback handler set to `ExtensibleFallbackHandler`.
2. The `Safe` has set the `domainVerifier` for the `GPv2Settlement.domainSeparator()` to `ComposableCoW`

#### Conditional order creation

A conditional order is a struct `ConditionalOrderParams`, consisting of:

1. The address of handler, ie. type of conditional order (such as `TWAP`).
2. A unique salt.
3. Implementation specific `staticInput` - data that is known at the creation time of the conditional order.

##### Single Order

1. From the context of the Safe that is placing the order, call `ComposableCoW.create` with the `ConditionalOrderParams` struct. Optionally set `dispatch = true` to have events emitted that are picked up by a watch tower.

##### Merkle Root

1. Collect all the conditional orders, which are multiple structs of `ConditionalOrderParams`.
2. Populate a merkle tree with the leaves from (1), where each leaf is a double hashed of the ABI-encoded struct.
3. Determine the merkle root of the tree and set this as the root, calling `ComposableCoW.setRoot`. The `proof` must be set, and currently:
   a. Set a `location` of `0` for no proofs emitted.
   b. Otherwise, set a `location` of `1` at which case the payload in the proof will be interpreted as an array of proofs and indexed by the watch tower.

#### Get Tradeable Order With Signature

Conditional orders may generate one or many discrete orders depending on their implementation. To retrieve a discrete order that is valid at the current block:

1. Call `ComposableCoW.getTradeableOrderWithSignature(address owner, ConditionalOrderParams params, bytes offchainInput, bytes32[] proof)` where:
   - `owner`: smart contract / `Safe`
   - `params`: mentioned above.
   - `offchainInput` is any implementation specific offchain input for discrete order generation / validation.
   - `proof`: a zero length array if a single order, otherwise the merkle proof for the merkle root that's set for `owner`.
2. Decoding the `GPv2Order`, use this data to populate a `POST` to the CoW Protocol API to create an order. Set the `signingScheme` to `eip1271` and the `signature` to that returned from the call in (1).
3. Review the order on [CoW Explorer](https://explorer.cow.fi/).
4. `getTradeableOrderWithSignature(address,ConditionalOrderParams,bytes,bytes32[])` may revert with one of the custom errors. This provides feedback for watch towers to modify their internal state.

#### Conditional order cancellation

##### Single Order

1. Determine the digest for the conditional order, ie.`H(Params)`.
2. Call `ComposableCoW.remove(H(Params))`

##### Merkle Root

1. Prune the leaf from the merkle tree.
2. Determine the new root.
3. Call `ComposableCoW.setRoot` with the new root, which will invalidate any orders that have been pruned from the tree.

## Time-weighted average price (TWAP)

A simple _time-weighted average price_ trade may be thought of as `n` smaller trades happening every `t` time interval, commencing at time `t0`. Additionally, it is possible to limit a part's validity of the order to a certain `span` of time interval `t`.

### Data Structure

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

If Alice also wanted to restrict the duration in which each part traded in each day, she may set `span` to a non-zero duration. For example, if Alice wanted to execute the TWAP, each day for 30 days, however only wanted to trade for the first 12 hours of each day, she would set `span` to `43200` (i.e. `60 * 60 * 12`).

Using `span` allows for use cases such as weekend or week-day only trading.

### Methodology

To create a TWAP order:

1. ABI-Encode the `IConditionalOrder.ConditionalOrderParams` struct with:
   - `handler`: set to the `TWAP` smart contract deployment.
   - `salt`: set to a unique value.
   - `staticInput`: the ABI-encoded `TWAP.Data` struct.
2. Use the `struct` from (1) as either a Merkle leaf, or with `ComposableCoW.create` to create a single conditional order.
3. Approve `GPv2VaultRelayer` to trade `n x partSellAmount` of the safe's `sellToken` tokens (in the example above, `GPv2VaultRelayer` would receive approval for spending 12,000,000 DAI tokens).

**NOTE**: When calling `ComposableCoW.create`, setting `dispatch = true` will cause `ComposableCoW` to emit event logs that are indexed by the watch tower automatically. If you wish to maintain a private order (and will submit to the CoW Protocol API through your own infrastructure, you may set `dispatch` to `false`).

Fortunately, when using Safe, it is possible to batch together all the above calls to perform this step atomically, and optimise gas consumption / UX. For code examples on how to do this, please refer to the [CLI](#CLI).

**TODO**
**NOTE:** For canceling a TWAP order, follow the instructions at [Conditional order cancellation](#Conditional-order-cancellation).

## Developers

### Requirements

- `forge` ([Foundry](https://github.com/foundry-rs/foundry))

### Deployed Contracts

| Contract Name                  | Ethereum Mainnet                                                                                                      | Gnosis Chain                                                                                                           | Sepolia                                                                                                                       | Arbitrum One                                                                                                         | Base                                                                                                                  |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |----------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `ExtensibleFallbackHandler`    | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://etherscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://gnosisscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://sepolia.etherscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://arbiscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://basescan.org/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) |
| `ComposableCoW`                | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://etherscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://gnosisscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://sepolia.etherscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://arbiscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://basescan.org/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) |
| `TWAP`                         | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://etherscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://gnosisscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://sepolia.etherscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://arbiscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://basescan.org/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) |
| `GoodAfterTime`                | [0xdaf33924925e03c9cc3a10d434016d6cfad0add5](https://etherscan.io/address/0xdaf33924925e03c9cc3a10d434016d6cfad0add5) | [0xdaf33924925e03c9cc3a10d434016d6cfad0add5](https://gnosisscan.io/address/0xdaf33924925e03c9cc3a10d434016d6cfad0add5) | [0xdaf33924925e03c9cc3a10d434016d6cfad0add5](https://sepolia.etherscan.io/address/0xdaf33924925e03c9cc3a10d434016d6cfad0add5) | [0xdaf33924925e03c9cc3a10d434016d6cfad0add5](https://arbiscan.io/address/0xdaf33924925e03c9cc3a10d434016d6cfad0add5) | [0xdaf33924925e03c9cc3a10d434016d6cfad0add5](https://basescan.org/address/0xdaf33924925e03c9cc3a10d434016d6cfad0add5) |
| `PerpetualStableSwap`          | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://etherscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://gnosisscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://sepolia.etherscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://arbiscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://basescan.org/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) |
| `TradeAboveThreshold`          | [0x812308712a6d1367f437e1c1e4af85c854e1e9f6](https://etherscan.io/address/0x812308712a6d1367f437e1c1e4af85c854e1e9f6) | [0x812308712a6d1367f437e1c1e4af85c854e1e9f6](https://gnosisscan.io/address/0x812308712a6d1367f437e1c1e4af85c854e1e9f6) | [0x812308712a6d1367f437e1c1e4af85c854e1e9f6](https://sepolia.etherscan.io/address/0x812308712a6d1367f437e1c1e4af85c854e1e9f6) | [0x812308712a6d1367f437e1c1e4af85c854e1e9f6](https://arbiscan.io/address/0x812308712a6d1367f437e1c1e4af85c854e1e9f6) | [0x812308712a6d1367f437e1c1e4af85c854e1e9f6](https://basescan.org/address/0x812308712a6d1367f437e1c1e4af85c854e1e9f6) |
| `StopLoss`                     | [0x412c36e5011cd2517016d243a2dfb37f73a242e7](https://etherscan.io/address/0x412c36e5011cd2517016d243a2dfb37f73a242e7) | [0x412c36e5011cd2517016d243a2dfb37f73a242e7](https://gnosisscan.io/address/0x412c36e5011cd2517016d243a2dfb37f73a242e7) | [0x412c36e5011cd2517016d243a2dfb37f73a242e7](https://sepolia.etherscan.io/address/0x412c36e5011cd2517016d243a2dfb37f73a242e7) | [0x412c36e5011cd2517016d243a2dfb37f73a242e7](https://arbiscan.io/address/0x412c36e5011cd2517016d243a2dfb37f73a242e7) | [0x412c36e5011cd2517016d243a2dfb37f73a242e7](https://basescan.org/address/0x412c36e5011cd2517016d243a2dfb37f73a242e7) |
| `CurrentBlockTimestampFactory` | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://etherscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://gnosisscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://sepolia.etherscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://arbiscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://basescan.org/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) |

#### Audits

The above deployed contracts have been audited by:

- Ackee Blockchain: [CoW Protocol - `ComposableCoW` and `ExtensibleFallbackHandler`](./audits/ackee-blockchain-cow-protocol-composablecow-extensiblefallbackhandler-report-1.2.pdf)
- Gnosis internal audit: [ComposableCoW - May/July 2023](./audits/gnosis-ComposableCoWMayJul2023.pdf)
- Gnosis internal audit (August 2024): [ComposableCoW - Diff between May/July 2023 and August 2024](./audits/Composable_CoW_Diff.pdf)

### Environment setup

Copy the `.env.example` to `.env` and set the applicable configuration variables for the testing / deployment environment.

### Testing

Effort has been made to adhere as close as possible to [best practices](https://book.getfoundry.sh/tutorials/best-practices), with _unit_, _fuzzing_ and _fork_ tests being implemented.

**NOTE:** Fuzz tests also include a `simulate` that runs full end-to-end integration testing, including the ability to settle conditional orders. Fork testing simulates end-to-end against production ethereum mainnet contracts, and as such requires `ETH_RPC_URL` to be defined (this should correspond to an archive node).

```bash
forge test -vvv --no-match-test "fork|[fF]uzz" # Basic unit testing only
forge test -vvv --no-match-test "fork" # Unit and fuzz testing
forge test -vvv # Unit, fuzz, and fork testing
```

### Coverage

```bash
forge coverage -vvv --no-match-test "fork" --report summary
```

### Deployment

Deployment is handled by solidity scripts in `forge`. The network being deployed to is dependent on the `ETH_RPC_URL`.

To deploy all contracts in a single run, run:

```bash
source .env
forge script script/deploy_ProdStack.s.sol:DeployProdStack --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
```

To deploy individual contracts:

```bash
# Deploy ComposableCoW
forge script script/deploy_ComposableCoW.s.sol:DeployComposableCoW --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
# Deploy order types
forge script script/deploy_OrderTypes.s.sol:DeployOrderTypes --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
```

The `broadcast` directory collects the latest run of the deployment script by network and is updated manually.
When the script is ran, the corresponding files can be found in the folder `broadcast/deploy_OrderTypes.s.sol/`.

#### Local deployment

For local integration testing, including the use of [Watch Tower](https://github.com/cowprotocol/tenderly-watch-tower), it may be useful deploying to a _forked_ mainnet environment. This can be done with `anvil`.

1. Open a terminal and run `anvil`:

   ```bash
   anvil --code-size-limit 50000 --block-time 5
   ```

   **NOTE**: When deploying the full stack on `anvil`, the balancer vault may exceed contract code size limits necessitating the use of `--code-size-limit`.

2. Follow the previous deployment directions, with this time specifying `anvil` as the RPC-URL:

   ```bash
   source .env
   forge script script/deploy_AnvilStack.s.sol:DeployAnvilStack --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
   ```

   **NOTE**: Within the output of the above command, there will be an address for a `Safe` that was deployed to `anvil`. This is needed for the next step.

   **NOTE:** `--verify` is omitted as with local deployments, these should not be submitted to Etherscan for verification.

3. To then simulate the creation of a single order:

   ```bash
   source .env
   SAFE="address here" forge script script/submit_SingleOrder.s.sol:SubmitSingleOrder --rpc-url http://127.0.0.1:8545 --broadcast
   ```
