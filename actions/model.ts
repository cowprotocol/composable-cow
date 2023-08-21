import Slack = require("node-slack");

import { Context, Storage } from "@tenderly/actions";
import { Transaction as SentryTransaction } from "@sentry/node";
import { BytesLike, ethers } from "ethers";

import { apiUrl, getProvider } from "./utils";
import type { IConditionalOrder } from "./types/ComposableCoW";

// Standardise the storage key
const LAST_NOTIFIED_ERROR_STORAGE_KEY = "LAST_NOTIFIED_ERROR";

export const getOrdersStorageKey = (network: string): string => {
  return `CONDITIONAL_ORDER_REGISTRY_${network}`;
};

export interface ExecutionContext {
  registry: Registry;
  notificationsEnabled: boolean;
  slack?: Slack;
  sentryTransaction?: SentryTransaction;
  context: Context;
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
export enum OrderStatus {
  SUBMITTED = 1,
  FILLED = 2,
}

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

    const ownerOrders = JSON.parse(str, _reviver);
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

export class ChainContext {
  provider: ethers.providers.Provider;
  api_url: string;

  constructor(provider: ethers.providers.Provider, api_url: string) {
    this.provider = provider;
    this.api_url = api_url;
  }

  public static async create(
    context: Context,
    network: string
  ): Promise<ChainContext> {
    const provider = await getProvider(context, network);

    const providerNetwork = await provider.getNetwork();
    return new ChainContext(provider, apiUrl(network));
  }
}

export function _reviver(_key: any, value: any) {
  if (typeof value === "object" && value !== null) {
    if (value.dataType === "Map") {
      return new Map(value.value);
    } else if (value.dataType === "Set") {
      return new Set(value.value);
    }
  }
  return value;
}

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

export type SmartOrderValidationResult<T> =
  | SmartOrderValidationSuccess<T>
  | SmartOrderValidationError;

export enum ValidationResult {
  Success,
  Failed,
  FailedButIsExpected,
}

export type SmartOrderValidationSuccess<T> = {
  result: ValidationResult.Success;
  data: T;
};
export type SmartOrderValidationError = {
  result: ValidationResult.Failed | ValidationResult.FailedButIsExpected;
  deleteConditionalOrder: boolean;
  errorObj: any;
};

export type SmartOrderValidator = (
  params: ValidateOrderParams
) => Promise<SmartOrderValidationResult<void>>;
export interface ValidateOrderParams {
  handler: string;
  salt: BytesLike;
  staticInput: BytesLike;
}
