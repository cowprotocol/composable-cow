import {
  ActionFn,
  BlockEvent,
  Context,
  Event,
  Log,
  TransactionEvent,
} from "@tenderly/actions";

import { BigNumber } from "ethers";

import { GPv2Settlement__factory } from "./types";
import { GPv2SettlementInterface } from "./types/GPv2Settlement";

import { handleExecutionError, init, writeRegistry } from "./utils";
import { OrderStatus, Registry } from "./model";

/**
 * Watch for settled trades and update the registry
 * @param context tenderly context
 * @param event transaction event
 */
export const checkForSettlement: ActionFn = async (
  context: Context,
  event: Event
) => {
  return _checkForSettlement(context, event).catch(handleExecutionError);
};

/**
 * Asynchronous version of checkForSettlement. It will process all the settlements, and will throw an error at the end if there was at least one error
 */
const _checkForSettlement: ActionFn = async (
  context: Context,
  event: Event
) => {
  const transactionEvent = event as TransactionEvent;
  const settlement = GPv2Settlement__factory.createInterface();

  const { registry } = await init(
    "checkForSettlement",
    transactionEvent.network,
    context
  );

  let hasErrors = false;
  for (const log of transactionEvent.logs) {
    const { error } = await _processSettlement(
      transactionEvent.hash,
      log,
      settlement,
      registry
    );
    hasErrors ||= error;
  }

  // Update the registry
  hasErrors ||= !(await writeRegistry());

  // Throw execution error if there was at least one error
  if (hasErrors) {
    throw Error(
      "[checkForSettlement] Error while checking the settlements to mark orders as FILLED"
    );
  }
};

async function _processSettlement(
  tx: string,
  log: Log,
  settlement: GPv2SettlementInterface,
  registry: Registry
): Promise<{ error: boolean }> {
  const { ownerOrders } = registry;
  try {
    if (log.topics[0] === settlement.getEventTopic("Trade")) {
      const [owner, , , , , , orderUid] = settlement.decodeEventLog(
        "Trade",
        log.data,
        log.topics
      ) as [string, string, string, BigNumber, BigNumber, BigNumber, string];

      // Check if the owner is in the registry
      if (ownerOrders.has(owner)) {
        // Get the conditionalOrders for the owner
        const conditionalOrders = ownerOrders.get(owner) ?? [];
        // Iterate over the conditionalOrders and update the status of the orderUid
        for (const conditionalOrder of conditionalOrders) {
          // Check if the orderUid is in the conditionalOrder
          if (conditionalOrder.orders.has(orderUid)) {
            // Update the status of the orderUid to FILLED
            console.log(
              `Update order ${orderUid} to status FILLED. Settlement Tx: ${tx}`
            );
            conditionalOrder.orders.set(orderUid, OrderStatus.FILLED);
          }
        }
      }
    }
  } catch (e: any) {
    console.error("Error checking for settlement", e);

    return { error: true };
  }

  return { error: false };
}
