# `ComposableCoW`: Composable Conditional orders

This repository is the next in evolution of the [`conditional-smart-orders`](https://github.com/cowprotocol/conditional-smart-orders), providing a unified interface for stateless, composable conditional orders. `ComposableCoW` is designed to be used with the [`ExtensibleFallbackHandler`](https://github.com/rndlabs/safe-contracts/tree/merged-efh-sigmuxer), a powerful _extensible_ fallback handler that allows for significant customisation of a `Safe`, while preserving strong security guarantees.

## Architecture

A detailed explanation on the architecture is available [here](https://hackmd.io/@mfw78/ByFP7Iazn).

### Methodology

For the purposes of outlining the methodologies, it is assumed that:

1. The `Safe` has already had it's fallback handler set to `ExtensibleFallbackHandler`.
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
   b. Otherwise, set a `location` of `1` at which case the payload in the proof will be interpted as an array of proofs and indexed by the watch tower.

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

If Alice also wanted to restrict the duration in which each part traded in each day, she may set `span` to a non-zero duration. For example, if Alice wanted to execute the TWAP, each day for 30 days, however only wanted to trade for the first 12 hours of each day, she would set `span` to `43200` (ie. `60 * 60 * 12`).

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
**NOTE:** For cancelling a TWAP order, follow the instructions at [Conditional order cancellation](#Conditional-order-cancellation).

## CLI

The CLI utility provided contains help functions to see all the options / configurability available for each subcommand.

**CAUTION:** This utility handles private keys for proposing transactions to Safes. Standard safety precautions associated with private key handling applies. It is recommended to **NEVER** pass private keys directly via command line as this may expose sensitive keys to those who have access to list processes running on your machine.

### Enviroment setup

Copy `.env.example` to `.env`, setting at least the `PRIVATE_KEY` and `ETH_RPC_URL`. Then build the project, in the root directory of the repository:

```bash
yarn build
```

### Usage

```
Dispatch conditional orders on Safe using composable CoW Protocol

Options:
  -V, --version                   output the version number
  -h, --help                      display help for command

Commands:
  create-twap [options]           Create a TWAP order
  set-fallback-handler [options]  Set the fallback handler of the Safe
  set-domain-verifier [options]   Set the CoW Protocol domain verifier of the Safe
  help [options] [command]        display help for command
```

1. Setting a safe's fallback handler

   ```bash
   yarn ts-node cli/cli.ts set-fallback-handler -s <SAFE_ADDRESS> -c <COMPOSABLE_COW_ADDRESS> -r <RPC_URL> --handler <EXTENSIBLE_FALLBACK_HANDLER>
   ```

   Check your safe's transaction queue and you should see the newly created transaction.

2. Setting an `ExtensibleFallbackHandler`-enabled Safe's `domainVerifier` for `GPv2Settlement`:

   ```bash
   yarn ts-node cli.ts set-domain-verifier -s <SAFE_ADDRESS> -c <COMPOSABLE_COW_ADDRESS> -r <RPC_URL>
   ```

3. Creating a TWAP order

   The CLI utility will automatically do some math for you. All order creation is from the perspective of _totals_. By specifying the `--sell-token`, `--buy-token`, `--total-sell-amount`, and `--total-min-buyamount`, the CLI will automatically determine the number of decimals, parse the values, and divide the totals by the number of parts (`-n`), using the results as the basis for the TWAP order.

   ```bash
   yarn ts-node cli.ts create-twap -s <SAFE_ADDRESS> -c <COMPOSABLE_COW_ADDRESS> --sell-token <SELL_TOKEN_ADDRESS> --buy-token <BUY_TOKEN_ADDRESS> --total-sell-amount 1000 --total-min-buy-amount 1 -n 6 -t 60000 -r <RPC_URL> -h <TWAP_HANDLER_ADDRESS>
   ```

   Check your safe' transaction queue, and you should see a newly created transaction that batches together the creation of the single conditional order and approving `GPv2VaultRelayer` on `sellToken` for `total-sell-amount`, and emits the order by setting `dispatch = true` in the creation.

   **NOTE:** When creating TWAP orders, the `--total-sell-amount` and `--total-min-buy-amount` are specified in whole units of the respective ERC20 token. For example, if wanting to buy a total amount of 1 WETH, specify `--total-min-buy-amount 1`. The CLI will automatically determine decimals and specify these appropriately.

4. Cancelling a conditional order

   **TODO**

## Tenderly Actions

A watchdog has been implementing using [Tenderly Actions](https://docs.tenderly.co/web3-actions/intro-to-web3-actions). By means of _emitted Event_ and new block monitoring, conditional orders can run autonomously.

Notably, with the `CondtionalOrderCreated` and `MerkleRootSet` events, multiple conditional orders can be created for one safe - in doing so, the actions maintain a registry of:

1. Safes that have created _at least one conditional order_.
2. All payloads for conditional orders by safe that have not expired or been cancelled.
3. All part orders by `orderUid` containing their status (`SUBMITTED`, `FILLED`) - the `Trade` on `GPv2Settlement` is monitored to determine if an order is `FILLED`.

As orders expire, or are cancelled, they are removed from the registry to conserve storage space.

### Local testing

This is asusming that you have followed the instructions for deploying the stack on `anvil` in [local deployment](#Local-deployment)

From the root directory of the repository:

```bash
yarn build
ETH_RPC_URL=http://127.0.0.1:8545 yarn ts-node ./actions/test/run_local.ts
```

### Deployment

If running your own watch tower, or deploying for production:

```bash
tenderly actions deploy
```

Make sure you configure the secrets in Tenderly:

- `NODE_URL_${network}`: RPC Node URL
- `NODE_USER_${network}`: (optional) RPC Node user name for basic auth.
- `NODE_PASSWORD_${network}`: (optional) RPC Node password name for basic auth.
- `NOTIFICATIONS_ENABLED`: (default `true`) Set to `false` to disable Slack notifications
- `SLACK_WEBHOOK_URL`: Slack Webhook (required only if notifications are enabled)
- `SENTRY_DSN`: (optional) Sentry DSN code. If present, it will enable Sentry notifications

## Developers

### Requirements

- `forge` ([Foundry](https://github.com/foundry-rs/foundry))
- `node` (`>= v16.18.0`)
- `yarn`
- `npm`
- `tenderly`

### Deployed Contracts

| Contract Name                  | Ethereum Mainnet                                                                                                      | Goerli                                                                                                                       | Gnosis Chain                                                                                                           |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `ExtensibleFallbackHandler`    | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://etherscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://goerli.etherscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) | [0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5](https://gnosisscan.io/address/0x2f55e8b20D0B9FEFA187AA7d00B6Cbe563605bF5) |
| `ComposableCoW`                | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://etherscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://goerli.etherscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) | [0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74](https://gnosisscan.io/address/0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74) |
| `TWAP`                         | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://etherscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://goerli.etherscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) | [0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5](https://gnosisscan.io/address/0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5) |
| `GoodAfterTime`                | [0xd3338f21c89745e46af56aeaf553cf96ba9bc66f](https://etherscan.io/address/0xd3338f21c89745e46af56aeaf553cf96ba9bc66f) | [0xd3338f21c89745e46af56aeaf553cf96ba9bc66f](https://goerli.etherscan.io/address/0xd3338f21c89745e46af56aeaf553cf96ba9bc66f) | [0xd3338f21c89745e46af56aeaf553cf96ba9bc66f](https://gnosisscan.io/address/0xd3338f21c89745e46af56aeaf553cf96ba9bc66f) |
| `PerpetualStableSwap`          | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://etherscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://goerli.etherscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) | [0x519BA24e959E33b3B6220CA98bd353d8c2D89920](https://gnosisscan.io/address/0x519BA24e959E33b3B6220CA98bd353d8c2D89920) |
| `TradeAboveThreshold`          | [0x44569Cbd4E10dd5e97293337964Eff32d58ed352](https://etherscan.io/address/0x44569Cbd4E10dd5e97293337964Eff32d58ed352) | [0x44569Cbd4E10dd5e97293337964Eff32d58ed352](https://goerli.etherscan.io/address/0x44569Cbd4E10dd5e97293337964Eff32d58ed352) | [0x44569Cbd4E10dd5e97293337964Eff32d58ed352](https://gnosisscan.io/address/0x44569Cbd4E10dd5e97293337964Eff32d58ed352) |
| `StopLoss`                     | [0xE8212F30C28B4AAB467DF3725C14d6e89C2eB967](https://etherscan.io/address/0xE8212F30C28B4AAB467DF3725C14d6e89C2eB967) | [0xE8212F30C28B4AAB467DF3725C14d6e89C2eB967](https://goerli.etherscan.io/address/0xE8212F30C28B4AAB467DF3725C14d6e89C2eB967) | [0xE8212F30C28B4AAB467DF3725C14d6e89C2eB967](https://gnosisscan.io/address/0xE8212F30C28B4AAB467DF3725C14d6e89C2eB967) |
| `CurrentBlockTimestampFactory` | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://etherscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://goerli.etherscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) | [0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc](https://gnosisscan.io/address/0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc) |

#### Audits

The above deployed contracts have been audited by:

- Ackee Blockchain: [CoW Protocol - `ComposableCoW` and `ExtensibleFallbackHandler`](./audits/ackee-blockchain-cow-protocol-composablecow-extensiblefallbackhandler-report-1.2.pdf)
- Gnosis internal audit: [ComposableCoW - May/July 2023](./audits/gnosis-ComposableCoWMayJul2023.pdf)

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

For local integration testing, including the use of [Tenderly Actions](#Tenderly-actions), it may be useful deploying to a _forked_ mainnet environment. This can be done with `anvil`.

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

#### Run Tenderly Web3 Actions locally

> Useful for debugging locally the actions. Also could be used to create an order for an old block in case there was a failure of WatchTowers indexing it.

Make sure you setup the environment (so you have your own `.env` file).

Decide in which network you want to run the actions and provide the additional parameters for that network. For example:

```ini
NETWORK=100
NODE_URL_100=https://your-rpc-endpoint
NODE_USER_100=optionally-provide-user-if-auth-is-required
NODE_PASSWORD_100=optionally-provide-password-if-auth-is-required
```

```bash
# Build Actions
yarn build:actions

# Run actions locally
#   - It will start watching and processing new blocks
#   - As a result, new Composable Cow orders will be discovered and posted to the OrderBook API
yarn start:actions

# You can re-process an old block by:
#   - Add an env BLOCK_NUMBER
#   - Run actions locally
yarn start:actions
```
