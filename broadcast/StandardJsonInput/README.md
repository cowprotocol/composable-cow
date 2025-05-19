# Standard JSON input

This folder contains the standard JSON input to the Solidity compiler for the contracts in this repository.

Many block explorer (e.g., Etherscan-based ones) support verifying contract code directly through their interface by using these files.

They can be used as a last resort if other verification scripts don't work.

## Warning

Because of a [deployment issue](https://github.com/cowprotocol/composable-cow/issues/93), the contract bytecode doesn't fully match the compiled version.
This means that the standard input for the following contracts may not lead to full verification:

 - ExtensibleFallbackHandler
 - ComposableCoW
 - TWAP
 - GoodAfterTime
 - PerpetualStableSwap
 - TradeAboveThreshold
 - StopLoss
 - CurrentBlockTimestampFactory

Etherscan-based block explorers still consider the contract to be verified, since the bytecode differences (in the Solidity metadata) don't lead to a difference in the code that runs on-chain.
Other verifier will note this, for example Sourcify will only match the contract as partially verified.
