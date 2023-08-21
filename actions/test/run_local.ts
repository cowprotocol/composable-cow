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
import { getOrdersStorageKey } from "../model";
import { exit } from "process";

require("dotenv").config();

const main = async () => {
  // The web3 actions fetches the node url and computes the API based on the current chain id
  const network = process.env.NETWORK;
  assert(network, "network is required");

  const testRuntime = await _getRunTime(network);

  // Get provider
  const provider = await getProvider(testRuntime.context, network);
  const { chainId } = await provider.getNetwork();

  // Run one of the 2 Execution modes (single block, or watch mode)
  if (process.env.BLOCK_NUMBER) {
    // Execute once, for a specific block
    const blockNumber = Number(process.env.BLOCK_NUMBER);
    console.log(`[run_local] Processing specific block ${blockNumber}...`);
    await processBlock(provider, blockNumber, chainId, testRuntime).catch(
      () => {
        exit(100);
      }
    );
    console.log(`[run_local] Block ${blockNumber} has been processed.`);
  } else {
    // Watch for new blocks
    console.log(`[run_local] Subscribe to new blocks for network ${network}`);
    provider.on("block", async (blockNumber: number) => {
      try {
        await processBlock(provider, blockNumber, chainId, testRuntime);
      } catch (error) {
        console.error("[run_local] Error in processBlock", error);
      }
    });
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
  let hasErrors = false;
  for (const transaction of blockWithTransactions.transactions) {
    const receipt = await provider.getTransactionReceipt(transaction.hash);
    if (receipt) {
      const {
        hash,
        from,
        value,
        nonce,
        gasLimit,
        maxPriorityFeePerGas,
        maxFeePerGas,
      } = transaction;

      const testTransactionEvent: TestTransactionEvent = {
        blockHash: block.hash,
        blockNumber: block.number,
        from,
        hash,
        network: chainId.toString(),
        logs: receipt.logs,
        input: "",
        value: value.toString(),
        nonce: nonce.toString(),
        gas: gasLimit.toString(),
        gasUsed: receipt.gasUsed.toString(),
        cumulativeGasUsed: receipt.cumulativeGasUsed.toString(),
        gasPrice: receipt.effectiveGasPrice.toString(),
        gasTipCap: maxPriorityFeePerGas ? maxPriorityFeePerGas.toString() : "",
        gasFeeCap: maxFeePerGas ? maxFeePerGas.toString() : "",
        transactionHash: transaction.hash,
      };

      // run action
      console.log(`[run_local] Run "addContract" action for TX ${hash}`);
      const result = await testRuntime
        .execute(addContract, testTransactionEvent)
        .then(() => true)
        .catch((e) => {
          hasErrors = true;
          console.error(
            `[run_local] Error running "addContract" action for TX:`,
            e
          );
          return false;
        });
      console.log(
        `[run_local] Result of "addContract" action for TX ${hash}: ${_formatResult(
          result
        )}`
      );
    }
  }

  // Block watcher for creating new orders
  const testBlockEvent = new TestBlockEvent();
  testBlockEvent.blockNumber = blockNumber;
  testBlockEvent.blockDifficulty = block.difficulty.toString();
  testBlockEvent.blockHash = block.hash;
  testBlockEvent.network = chainId.toString();

  // run action
  console.log(`[run_local] checkForAndPlaceOrder for block ${blockNumber}`);
  const result = await testRuntime
    .execute(checkForAndPlaceOrder, testBlockEvent)
    .then(() => true)
    .catch((e) => {
      hasErrors = true;
      console.log(
        `[run_local] Error running "checkForAndPlaceOrder" action`,
        e
      );
      return false;
    });
  console.log(
    `[run_local] Result of "checkForAndPlaceOrder" action for block ${blockNumber}: ${_formatResult(
      result
    )}`
  );

  if (hasErrors) {
    throw new Error("[run_local] Errors found in processing block");
  }
}

async function _getRunTime(network: string): Promise<TestRuntime> {
  const testRuntime = new TestRuntime();

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

  // Load storage from env
  const storage = process.env.STORAGE;
  if (storage) {
    const storageFormatted = JSON.stringify(JSON.parse(storage), null, 2);
    console.log("[run_local] Loading storage from env", storageFormatted);
    await testRuntime.context.storage.putStr(
      getOrdersStorageKey(network),
      storage
    );
  }

  return testRuntime;
}

function _formatResult(result: boolean) {
  return result ? "✅" : "❌";
}

(async () => await main())();
