import {
  ActionFn,
  BlockEvent,
  Context,
  Event,
  TransactionEvent,
} from "@tenderly/actions";
import {
  Order,
  OrderBalance,
  OrderKind,
  computeOrderUid,
} from "@cowprotocol/contracts";

import axios from "axios";
import { BigNumber, ethers } from "ethers";
import { ComposableCoW__factory, GPv2Settlement__factory } from "./types";
import { Registry, OrderStatus } from "./register";
import { BytesLike, Logger } from "ethers/lib/utils";

const GPV2SETTLEMENT = "0x9008D19f58AAbD9eD0D60971565AA8510560ab41";
const COMPOSABLE_COW = "0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead";

/**
 * Watch for settled trades and update the registry
 * @param context tenderly context
 * @param event transaction event
 */
export const checkForSettlement: ActionFn = async (
  context: Context,
  event: Event
) => {
  const transactionEvent = event as TransactionEvent;
  const iface = GPv2Settlement__factory.createInterface();

  const registry = await Registry.load(context, transactionEvent.network);
  console.log(
    `Current registry: ${JSON.stringify(
      Array.from(registry.ownerOrders.entries())
    )}`
  );

  transactionEvent.logs.forEach((log) => {
    if (log.topics[0] === iface.getEventTopic("Trade")) {
      const [owner, , , , , , orderUid] = iface.decodeEventLog(
        "Trade",
        log.data,
        log.topics
      ) as [string, string, string, BigNumber, BigNumber, BigNumber, string];

      // Check if the owner is in the registry
      if (registry.ownerOrders.has(owner)) {
        // Get the conditionalOrders for the owner
        const conditionalOrders = registry.ownerOrders.get(owner);
        // Iterate over the conditionalOrders and update the status of the orderUid
        conditionalOrders?.forEach((conditionalOrder) => {
          // Check if the orderUid is in the conditionalOrder
          if (conditionalOrder.orders.has(orderUid)) {
            // Update the status of the orderUid to FILLED
            conditionalOrder.orders.set(orderUid, OrderStatus.FILLED);
          }
        });
      }
    }
  });

  console.log(
    `Updated registry: ${JSON.stringify(
      Array.from(registry.ownerOrders.entries())
    )}`
  );
  await registry.write();
};

/**
 * Watch for new blocks and check for orders to place
 * @param context tenderly context
 * @param event block event
 */
export const checkForAndPlaceOrder: ActionFn = async (
  context: Context,
  event: Event
) => {
  const blockEvent = event as BlockEvent;
  const registry = await Registry.load(context, blockEvent.network);
  const chainContext = await ChainContext.create(context, blockEvent.network);

  // enumerate all the owners
  for (const [owner, conditionalOrders] of registry.ownerOrders.entries()) {
    console.log(`Checking ${owner}...`);

    // enumerate all the `ConditionalOrder`s for a given owner
    for (const conditionalOrder of conditionalOrders) {
      console.log(`Checking params ${conditionalOrder.params}...`);
      const contract = ComposableCoW__factory.connect(
        COMPOSABLE_COW,
        chainContext.provider
      );
      try {
        const { order, signature } =
          await contract.callStatic.getTradeableOrderWithSignature(
            owner,
            conditionalOrder.params,
            "0x",
            conditionalOrder.proof ? conditionalOrder.proof.path : []
          );

        const orderToSubmit: Order = {
          ...order,
          kind: OrderKind.SELL,
          sellTokenBalance: OrderBalance.ERC20,
          buyTokenBalance: OrderBalance.ERC20,
        };

        // calculate the orderUid
        const orderUid = computeOrderUid(
          {
            name: "Gnosis Protocol",
            version: "v2",
            chainId: blockEvent.network,
            verifyingContract: GPV2SETTLEMENT,
          },
          {
            ...orderToSubmit,
            receiver:
              orderToSubmit.receiver === ethers.constants.AddressZero
                ? undefined
                : orderToSubmit.receiver,
          },
          owner
        );

        // if the orderUid has not been submitted, or filled, then place the order
        if (!conditionalOrder.orders.has(orderUid)) {
          console.log(
            `Placing orderuid ${orderUid} with Order: ${JSON.stringify(order)}`
          );

          await placeOrder(
            { ...orderToSubmit, from: owner, signature },
            chainContext.api_url
          );

          conditionalOrder.orders.set(orderUid, OrderStatus.SUBMITTED);
        } else {
          console.log(
            `OrderUid ${orderUid} status: ${conditionalOrder.orders.get(
              orderUid
            )}`
          );
        }
      } catch (e: any) {
        if (e.code === Logger.errors.CALL_EXCEPTION) {
          switch (e.errorName) {
            case "OrderNotValid":
              // The conditional order has not expired, or been cancelled, but the order is not valid
              // For example, with TWAPs, this may be after `span` seconds have passed in the epoch.
              continue;
            case "SingleOrderNotAuthed":
              console.log(
                `Single order on safe ${owner} not authed. Unfilled orders:`
              );
            case "ProofNotAuthed":
              console.log(
                `Proof on safe ${owner} not authed. Unfilled orders:`
              );
          }
          printUnfilledOrders(conditionalOrder.orders);
          console.log("Removing conditional order from registry");
          conditionalOrders.delete(conditionalOrder);
        }

        console.log(`Not tradeable (${e})`);
      }
    }
  }

  // Update the registry
  await registry.write();
};

// --- Helpers ---

/**
 * Print a list of all the orders that were placed and not filled
 * @param orders All the orders that are being tracked
 */
export const printUnfilledOrders = (orders: Map<BytesLike, OrderStatus>) => {
  console.log("Unfilled orders:");
  for (const [orderUid, status] of orders.entries()) {
    if (status === OrderStatus.SUBMITTED) {
      console.log(orderUid);
    }
  }
};

/**
 * Place a new order
 * @param order to be placed on the cow protocol api
 * @param api_url rest api url
 */
async function placeOrder(order: any, api_url: string) {
  try {
    const { data } = await axios.post(
      `${api_url}/api/v1/orders`,
      {
        sellToken: order.sellToken,
        buyToken: order.buyToken,
        receiver: order.receiver,
        sellAmount: order.sellAmount.toString(),
        buyAmount: order.buyAmount.toString(),
        validTo: order.validTo,
        appData: order.appData,
        feeAmount: order.feeAmount.toString(),
        kind: kindToString(order.kind),
        partiallyFillable: order.partiallyFillable,
        sellTokenBalance: balanceToString(order.sellTokenBalance),
        buyTokenBalance: balanceToString(order.buyTokenBalance),
        signingScheme: "eip1271",
        signature: order.signature,
        from: order.from,
      },
      {
        headers: {
          "Content-Type": "application/json",
          accept: "application/json",
        },
      }
    );
    console.log(`API response: ${data}`);
  } catch (error: any) {
    if (error.response) {
      // The request was made and the server responded with a status code
      // that falls out of the range of 2xx
      console.log(error.response.status);
      console.log(error.response.data);
    } else if (error.request) {
      // The request was made but no response was received
      // `error.request` is an instance of XMLHttpRequest in the browser and an instance of
      // http.ClientRequest in node.js
      console.log(error.request);
    } else if (error.message) {
      // Something happened in setting up the request that triggered an Error
      console.log("Error", error.message);
    } else {
      console.log(error);
    }
    throw error;
  }
}

/**
 * Convert an order kind hash to a string
 * @param kind of order in hash format
 * @returns string representation of the order kind
 */
export const kindToString = (kind: string) => {
  if (
    kind ===
    "0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775"
  ) {
    return "sell";
  } else if (
    kind ===
    "0x6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc"
  ) {
    return "buy";
  } else {
    throw new Error(`Unknown kind: ${kind}`);
  }
};

/**
 * Convert a balance source/destination hash to a string
 * @param balance balance source/destination hash
 * @returns string representation of the balance
 * @throws if the balance is not recognized
 */
export const balanceToString = (balance: string) => {
  if (
    balance ===
    "0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9"
  ) {
    return "erc20";
  } else if (
    balance ===
    "0xabee3b73373acd583a130924aad6dc38cfdc44ba0555ba94ce2ff63980ea0632"
  ) {
    return "external";
  } else if (
    balance ===
    "0x4ac99ace14ee0a5ef932dc609df0943ab7ac16b7583634612f8dc35a4289a6ce"
  ) {
    return "internal";
  } else {
    throw new Error(`Unknown balance type: ${balance}`);
  }
};

class ChainContext {
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
    const node_url = await context.secrets.get(`NODE_URL_${network}`);
    const provider = new ethers.providers.JsonRpcProvider(node_url);
    return new ChainContext(provider, apiUrl(network));
  }
}

function apiUrl(network: string): string {
  switch (network) {
    case "1":
      return "https://api.cow.fi/mainnet";
    case "5":
      return "https://api.cow.fi/goerli";
    case "100":
      return "https://api.cow.fi/xdai";
    default:
      throw "Unsupported network";
  }
}
