import {
  ActionFn,
  Context,
  Event,
  TransactionEvent,
  Log,
} from "@tenderly/actions";
import { BytesLike, ethers } from "ethers";

import type {
  ComposableCoW,
  ComposableCoWInterface,
  IConditionalOrder,
} from "./types/ComposableCoW";
import { ComposableCoW__factory } from "./types/factories/ComposableCoW__factory";

import { handleExecutionError, init, writeRegistry } from "./utils";
import { Owner, Proof, Registry } from "./model";

/**
 * Listens to these events on the `ComposableCoW` contract:
 * - `ConditionalOrderCreated`
 * - `MerkleRootSet`
 * @param context tenderly context
 * @param event transaction event
 */
export const addContract: ActionFn = async (context: Context, event: Event) => {
  return _addContract(context, event).catch(handleExecutionError);
};

const _addContract: ActionFn = async (context: Context, event: Event) => {
  const transactionEvent = event as TransactionEvent;
  const tx = transactionEvent.hash;
  const composableCow = ComposableCoW__factory.createInterface();
  const { registry } = await init(
    "addContract",
    transactionEvent.network,
    context
  );

  // Process the logs
  let hasErrors = false;
  transactionEvent.logs.forEach((log) => {
    const { error } = _registerNewOrder(tx, log, composableCow, registry);
    hasErrors ||= error;
  });

  hasErrors ||= !(await writeRegistry());
  // Throw execution error if there was at least one error
  if (hasErrors) {
    throw Error(
      "[addContract] Error adding conditional order. Event: " + event
    );
  }
};

export function _registerNewOrder(
  tx: string,
  log: Log,
  composableCow: ComposableCoWInterface,
  registry: Registry
): { error: boolean } {
  try {
    // Check if the log is a ConditionalOrderCreated event
    if (
      log.topics[0] === composableCow.getEventTopic("ConditionalOrderCreated")
    ) {
      const [owner, params] = composableCow.decodeEventLog(
        "ConditionalOrderCreated",
        log.data,
        log.topics
      ) as [string, IConditionalOrder.ConditionalOrderParamsStruct];

      // Attempt to add the conditional order to the registry
      add(tx, owner, params, null, log.address, registry);
    } else if (log.topics[0] == composableCow.getEventTopic("MerkleRootSet")) {
      const [owner, root, proof] = composableCow.decodeEventLog(
        "MerkleRootSet",
        log.data,
        log.topics
      ) as [string, BytesLike, ComposableCoW.ProofStruct];

      // First need to flush the owner's conditional orders that do not have the merkle root set
      flush(owner, root, registry);

      // Only continue processing if the proofs have been emitted
      if (proof.location === 1) {
        // Decode the proof.data
        const proofData = ethers.utils.defaultAbiCoder.decode(
          ["bytes[]"],
          proof.data as BytesLike
        );
        proofData.forEach((order) => {
          // Decode the order
          const decodedOrder = ethers.utils.defaultAbiCoder.decode(
            [
              "bytes32[]",
              "tuple(address handler, bytes32 salt, bytes staticInput)",
            ],
            order as BytesLike
          );
          // Attempt to add the conditional order to the registry
          add(
            tx,
            owner,
            decodedOrder[1],
            { merkleRoot: root, path: decodedOrder[0] },
            log.address,
            registry
          );
        });
      }
    }
  } catch (error) {
    console.error(
      "[addContract] Error handling ConditionalOrderCreated/MerkleRootSet event" +
        error
    );
    return { error: true };
  }

  return { error: false };
}

/**
 * Attempt to add an owner's conditional order to the registry
 *
 * @param owner to add the conditional order to
 * @param params for the conditional order
 * @param proof for the conditional order (if it is part of a merkle root)
 * @param composableCow address of the ComposableCoW contract that emitted the event
 * @param registry of all conditional orders
 */
export const add = async (
  tx: string,
  owner: Owner,
  params: IConditionalOrder.ConditionalOrderParamsStruct,
  proof: Proof | null,
  composableCow: string,
  registry: Registry
) => {
  const { handler, salt, staticInput } = params;
  if (registry.ownerOrders.has(owner)) {
    const conditionalOrders = registry.ownerOrders.get(owner);
    console.log(
      `[register:add] Adding conditional order to already existing owner contract ${owner}`,
      { tx, handler, salt, staticInput }
    );
    let exists: boolean = false;
    // Iterate over the conditionalOrders to make sure that the params are not already in the registry
    for (const conditionalOrder of conditionalOrders?.values() ?? []) {
      // Check if the params are in the conditionalOrder
      if (conditionalOrder.params === params) {
        exists = true;
        break;
      }
    }

    // If the params are not in the conditionalOrder, add them
    if (!exists) {
      conditionalOrders?.add({
        tx,
        params,
        proof,
        orders: new Map(),
        composableCow,
      });
    }
  } else {
    console.log(
      `[register:add] Adding conditional order to new owner contract ${owner}:`,
      { tx, handler, salt, staticInput }
    );
    registry.ownerOrders.set(
      owner,
      new Set([{ tx, params, proof, orders: new Map(), composableCow }])
    );
  }
};

/**
 * Flush the conditional orders of an owner that do not have the merkle root set
 * @param owner to check for conditional orders to flush
 * @param root the merkle root to check against
 * @param registry of all conditional orders
 */
export const flush = async (
  owner: Owner,
  root: BytesLike,
  registry: Registry
) => {
  if (registry.ownerOrders.has(owner)) {
    const conditionalOrders = registry.ownerOrders.get(owner);
    if (conditionalOrders !== undefined) {
      for (const conditionalOrder of conditionalOrders.values()) {
        if (
          conditionalOrder.proof !== null &&
          conditionalOrder.proof.merkleRoot !== root
        ) {
          // Delete the conditional order
          conditionalOrders.delete(conditionalOrder);
        }
      }
    }
  }
};
