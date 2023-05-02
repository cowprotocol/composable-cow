import {
  TestRuntime,
  TestBlockEvent,
  TestTransactionEvent,
} from "@tenderly/actions-test";
import { checkForAndPlaceOrder } from "../watch";
import { addContract } from "../register";
import { ethers } from "ethers";

const main = async () => {
  const testRuntime = new TestRuntime();

  const node_url = process.env["ETH_RPC_URL"];
  if (!node_url) {
    throw "Please specify your node url via the ETH_RPC_URL env variable";
  }

  // The web3 actions fetches the node url and computes the API based on the current chain id
  const provider = new ethers.providers.JsonRpcProvider(node_url);
  const { chainId } = await provider.getNetwork();
  await testRuntime.context.secrets.put(`NODE_URL_${chainId}`, node_url);

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
