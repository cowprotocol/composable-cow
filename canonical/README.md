# Canonical initcode

The initcode of the official deployments, one file per contract under `initcode/`, with
`manifest.json` recording each salt and resulting address. Read back from the deployment
transactions, not compiled from this repository: a fresh build produces a different metadata hash
and therefore a different address ([#93](https://github.com/cowprotocol/composable-cow/issues/93)).

Deploy it with [`dev/deploy-canonical.sh`](../dev/deploy-canonical.sh), which checks every file
against `manifest.json` before sending anything.

Don't edit these files. The salts are deliberately not uniform: `GoodAfterTime`, `StopLoss` and
`TradeAboveThreshold` were deployed with a zero salt, the rest with `v1.0.0`.
