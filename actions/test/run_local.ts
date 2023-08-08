import {
  TestRuntime,
  TestBlockEvent,
  TestTransactionEvent,
} from "@tenderly/actions-test";
import { checkForAndPlaceOrder } from "../watch";
import { addContract } from "../register";
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

  provider.on("block", async (blockNumber) => {
    // Block watcher for creating new orders
    const testBlockEvent = new TestBlockEvent();
    const block = await provider.getBlock(blockNumber);
    testBlockEvent.blockNumber = blockNumber;
    testBlockEvent.blockDifficulty = block.difficulty.toString();
    testBlockEvent.blockHash = block.hash;
    testBlockEvent.network = chainId.toString();

    // run action
    await testRuntime.execute(checkForAndPlaceOrder, testBlockEvent);

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
        await testRuntime.execute(addContract, testTransactionEvent);
      }
    }
  });
};

(async () => await main())();
