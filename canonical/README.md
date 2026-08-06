# Canonical initcode

The initcode of the official deployments, one file per contract under `initcode/`, with
`manifest.json` recording each salt and resulting address. Read back from the deployment
transactions, not compiled from this repository: a fresh build produces a different metadata hash
and therefore a different address ([#93](https://github.com/cowprotocol/composable-cow/issues/93)).

Deploy it with [`dev/deploy-canonical.sh`](../dev/deploy-canonical.sh), which checks every file
against `manifest.json` before sending anything. The target chain needs the
[deterministic deployment proxy](https://github.com/Arachnid/deterministic-deployment-proxy) at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, since its address is part of the `CREATE2` preimage;
the script stops if it is missing.

Don't edit these files. The salts are deliberately not uniform: `GoodAfterTime`, `StopLoss` and
`TradeAboveThreshold` were deployed with a zero salt, the rest with `v1.0.0`.

## New contracts don't belong here

A new contract type is deployed with the regular scripts, using `CREATE2` and a salt, which already
gives the same address on every chain.

## Doing it by hand

The script replays the same transaction this procedure sends, so either works:

- Go to a deployed contract in another network, open the creation TX (e.g. [ExtensibleFallbackHandler](https://etherscan.io/tx/0x33dcbc73a8797c69a5b3956539dd8d191cf3f190bcb27a4d4eca8556f030f574) in mainnet)
- Go to `Click to show more` and copy the `Input Data` in Original format, also copy the `to` address
- Use your favourite tool to make a transaction (e.g., [swiss-knife](https://transact.swiss-knife.xyz/send-tx?chainId=1))
- Use the corresponding `Input Data` and `to` and send the tx
- A new contract will be deployed using `CREATE2` to the same deterministic address
