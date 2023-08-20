import {
  TestRuntime,
  TestBlockEvent,
  TestTransactionEvent,
} from "@tenderly/actions-test";
import { checkForAndPlaceOrder } from "../checkForAndPlaceOrder";
import { addContract } from "../addContract";
import { ethers } from "ethers";
import assert = require("assert");
import { getProvider } from "../utils";

require("dotenv").config();

const main = async () => {
  const testRuntime = new TestRuntime();

  // The web3 actions fetches the node url and computes the API based on the current chain id
  const network = process.env.NETWORK;
  assert(network, "network is required");

  // Add secrets from local env (.env) for current network
  const envNames = [
    `NODE_URL_${network}`,
    `NODE_USER_${network}`,
    `NODE_PASSWORD_${network}`,
    "SLACK_WEBHOOK_URL",
    "NOTIFICATIONS_ENABLED",
    "SENTRY_DSN",
  ];
  for (const name of envNames) {
    const envValue = process.env[name];
    if (envValue) {
      await testRuntime.context.secrets.put(name, envValue);
    }
  }

  // Get provider
  const provider = await getProvider(testRuntime.context, network);
  const { chainId } = await provider.getNetwork();

  const onNewBlock = async (blockNumber: number) => {
    try {
      processBlock(provider, blockNumber, chainId, testRuntime);
    } catch (error) {
      console.error("[run_local] Error in processBlock", error);
    }
  };

  // Run one of the 2 Execution modes (single block, or watch mode)
  if (process.env.BLOCK_NUMBER) {
    // Execute once, for a specific block
    const blockNumber = Number(process.env.BLOCK_NUMBER);
    console.log(`[run_local] Processing specific block ${blockNumber}...`);
    await onNewBlock(blockNumber).catch(console.error);
    console.log(`[run_local] Block ${blockNumber} has been processed.`);
  } else {
    // Watch for new blocks
    console.log(`[run_local] Subscribe to new blocks for network ${network}`);
    provider.on("block", onNewBlock);
  }
};

async function processBlock(
  provider: ethers.providers.Provider,
  blockNumber: number,
  chainId: number,
  testRuntime: TestRuntime
) {
  const block = await provider.getBlock(blockNumber);

  // Transaction watcher for adding new contracts
  const blockWithTransactions = await provider.getBlockWithTransactions(
    blockNumber
  );
  for (const transaction of blockWithTransactions.transactions) {
    const receipt = await provider.getTransactionReceipt(transaction.hash);
    if (receipt) {
      const testTransactionEvent: TestTransactionEvent = {
        blockHash: block.hash,
        blockNumber: block.number,
        from: transaction.from,
        hash: transaction.hash,
        network: chainId.toString(),
        logs: receipt.logs,
        input: "",
        value: transaction.value.toString(),
        nonce: transaction.nonce.toString(),
        gas: transaction.gasLimit.toString(),
        gasUsed: receipt.gasUsed.toString(),
        cumulativeGasUsed: receipt.cumulativeGasUsed.toString(),
        gasPrice: receipt.effectiveGasPrice.toString(),
        gasTipCap: transaction.maxPriorityFeePerGas
          ? transaction.maxPriorityFeePerGas.toString()
          : "",
        gasFeeCap: transaction.maxFeePerGas
          ? transaction.maxFeePerGas.toString()
          : "",
        transactionHash: transaction.hash,
      };

      // run action
      await testRuntime
        .execute(addContract, testTransactionEvent)
        .catch((e) => {
          console.error(
            "[run_local] Error in addContract processing transaction:",
            e
          );
        });
    }
  }

  // Block watcher for creating new orders
  const testBlockEvent = new TestBlockEvent();
  testBlockEvent.blockNumber = blockNumber;
  testBlockEvent.blockDifficulty = block.difficulty.toString();
  testBlockEvent.blockHash = block.hash;
  testBlockEvent.network = chainId.toString();

  // run action
  await testRuntime
    .execute(checkForAndPlaceOrder, testBlockEvent)
    .catch((e) => {
      console.log(
        "[run_local] Error in checkForAndPlaceOrder processing block",
        e
      );
    });
}

(async () => await main())();
