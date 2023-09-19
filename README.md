# `ComposableCoW`: Composable Conditional orders

This repository is the next in evolution of [`conditional-smart-orders`](https://github.com/cowprotocol/conditional-smart-orders), providing a unified interface for limited state, composable conditional orders. `ComposableCoW` is designed to be used with the [`ExtensibleFallbackHandler`](https://github.com/rndlabs/safe-contracts), a powerful _extensible_ fallback handler that allows for significant customisation of a `Safe`, while preserving strong security guarantees.

## Architecture

A detailed explanation on the architecture is available [here](https://hackmd.io/@mfw78/ByFP7Iazn).

### Methodology

For the purposes of outlining the methodologies, it is assumed that:

1. A `Safe` has already had it's fallback handler set to `ExtensibleFallbackHandler`.
2. The `Safe` has set the `domainVerifier` for the `GPv2Settlement.domainSeparator()` to `ComposableCoW`.

#### Conditional order creation

A conditional order is a struct `ConditionalOrderParams`, consisting of:

1. The `handler` address, ie. this corresponds to the type of conditional order (such as `TWAP`).
2. A unique salt.
3. Implementation specific `staticInput` - data that is known at the creation time of the conditional order.

**CAUTION**: The `salt` within the `ConditionalOrderParams` SHOULD be cryptographically random if privacy for the order is desired (ie. privacy until order book placement). 

##### Single Order

1. From the context of the Safe that is placing the order, call `ComposableCoW.create` with the `ConditionalOrderParams` struct. Optionally set `dispatch = true` to signal to a `ComposableCoW`-compliant watchtower that the conditional order should be indexed.

##### Merkle Root

1. Collect all the conditional orders, which are multiple structs of `ConditionalOrderParams`.
2. Populate a merkle tree with the leaves from (1), where each leaf is a double hash of the ABI-encoded struct.
3. Determine the merkle root of the tree and set this as the root, calling `ComposableCoW.setRoot`. The `proof` must be set, and currently:
   a. Set a `location` of `0` for no proofs emitted.
   b. Otherwise, set a `location` of `1` at which case the payload in the proof will be interpreted as an array of proofs and indexed by the watch tower.
   c. Other `location` values are reserved.

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
3. Call `ComposableCoW.setRoot` with the new root, invalidating any orders that have been pruned from the tree.

## Order Types

For a detailed explanation of the respective order types, please see their respective documentation:

- [`TWAP`](./docs/types/TWAP.md)

## Developers

### Requirements

- `forge` ([Foundry](https://github.com/foundry-rs/foundry))

### Deployed Contracts

**WARNING**: No contracts from this branch have been deployed to production (mainnet / Gnosis Chain) and should not be used in production.

| Contract Name                  | Goerli                                                                                                      |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------- |
|  |  |

#### Audits

**WARNING**: This is branch contains changes that have not been audited. Please use the `main` branch for the latest audited version.

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

```bash
source .env
# Deploy ComposableCoW
forge script script/deploy_ComposableCoW.s.sol:DeployComposableCoW --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
# Deploy order types
forge script script/deploy_OrderTypes.s.sol:DeployOrderTypes --rpc-url $ETH_RPC_URL --broadcast -vvvv --verify
```

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
   forge scirpt script/deploy_AnvilStack.s.sol:DeployAnvilStack --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
   ```

   **NOTE**: Within the output of the above command, there will be an address for a `Safe` that was deployed to `anvil`. This is needed for the next step.

   **NOTE:** `--verify` is omitted as with local deployments, these should not be submitted to Etherscan for verification.

3. To then simulate the creation of a single order:

   ```bash
   source .env
   SAFE="address here" forge script script/submit_SingleOrder.s.sol:SubmitSingleOrder --rpc-url http://127.0.0.1:8545 --broadcast
   ```
