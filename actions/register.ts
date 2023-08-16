import {
  ActionFn,
  Context,
  Event,
  TransactionEvent,
  Storage,
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

// Standardise the storage key
const LAST_NOTIFIED_ERROR_STORAGE_KEY = "LAST_NOTIFIED_ERROR";

export const getOrdersStorageKey = (network: string): string => {
  return `CONDITIONAL_ORDER_REGISTRY_${network}`;
};

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
  const { registry } = await init(transactionEvent.network, context);

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
  if (registry.ownerOrders.has(owner)) {
    const conditionalOrders = registry.ownerOrders.get(owner);
    console.log(
      `[register:add] Adding conditional order ${params} to already existing contract ${owner}. Tx: ${tx}`
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
      `[register:add] Adding conditional order ${params} to new contract ${owner} . Tx: ${tx}`
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

// --- Types ---

export enum OrderStatus {
  SUBMITTED = 1,
  FILLED = 2,
}

/**
 * A merkle proof is a set of parameters:
 * - `merkleRoot`: the merkle root of the conditional order
 * - `path`: the path to the order in the merkle tree
 */
export type Proof = {
  merkleRoot: BytesLike;
  path: BytesLike[];
};

export type OrderUid = BytesLike;
export type Owner = string;

export type ConditionalOrder = {
  tx: string; // the transaction hash that created the conditional order (useful for debugging purposes)

  // the parameters of the conditional order
  params: IConditionalOrder.ConditionalOrderParamsStruct;
  // the merkle proof if the conditional order is belonging to a merkle root
  // otherwise, if the conditional order is a single order, this is null
  proof: Proof | null;
  // a map of discrete order hashes to their status
  orders: Map<OrderUid, OrderStatus>;
  // the address to poll for orders
  composableCow: string;
};

/**
 * Models the state beteween executions.
 * Contains a map of owners to conditional orders and the last time we sent an error.
 */
export class Registry {
  ownerOrders: Map<Owner, Set<ConditionalOrder>>;
  storage: Storage;
  network: string;
  lastNotifiedError: Date | null;

  /**
   * Instantiates a registry.
   * @param ownerOrders What map to populate the registry with
   * @param storage interface to the Tenderly storage
   * @param network Which network the registry is for
   */
  constructor(
    ownerOrders: Map<Owner, Set<ConditionalOrder>>,
    storage: Storage,
    network: string,
    lastNotifiedError: Date | null
  ) {
    this.ownerOrders = ownerOrders;
    this.storage = storage;
    this.network = network;
    this.lastNotifiedError = lastNotifiedError;
  }

  /**
   * Load the registry from storage.
   * @param context from which to load the registry
   * @param network that the registry is for
   * @returns a registry instance
   */
  public static async load(
    context: Context,
    network: string
  ): Promise<Registry> {
    const str = await context.storage.getStr(getOrdersStorageKey(network));
    const lastNotifiedError = await context.storage
      .getStr(LAST_NOTIFIED_ERROR_STORAGE_KEY)
      .then((isoDate) => (isoDate ? new Date(isoDate) : null))
      .catch(() => null);

    if (str === null || str === undefined || str === "") {
      return new Registry(
        new Map<Owner, Set<ConditionalOrder>>(),
        context.storage,
        network,
        lastNotifiedError
      );
    }

    const ownerOrders = JSON.parse(str, reviver);
    return new Registry(
      ownerOrders,
      context.storage,
      network,
      lastNotifiedError
    );
  }

  /**
   * Write the registry to storage.
   */
  public async write(): Promise<void> {
    const writeOrders = this.storage.putStr(
      getOrdersStorageKey(this.network),
      JSON.stringify(this.ownerOrders, replacer)
    );

    const writeLastNotifiedError =
      this.lastNotifiedError !== null
        ? this.storage.putStr(
            LAST_NOTIFIED_ERROR_STORAGE_KEY,
            this.lastNotifiedError.toISOString()
          )
        : Promise.resolve();

    return Promise.all([writeOrders, writeLastNotifiedError]).then(() => {});
  }
}

// --- Helper Functions ---

// Serializing and deserializing Maps and Sets
export function replacer(_key: any, value: any) {
  if (value instanceof Map) {
    return {
      dataType: "Map",
      value: Array.from(value.entries()),
    };
  } else if (value instanceof Set) {
    return {
      dataType: "Set",
      value: Array.from(value.values()),
    };
  } else {
    return value;
  }
}

export function reviver(_key: any, value: any) {
  if (typeof value === "object" && value !== null) {
    if (value.dataType === "Map") {
      return new Map(value.value);
    } else if (value.dataType === "Set") {
      return new Set(value.value);
    }
  }
  return value;
}
