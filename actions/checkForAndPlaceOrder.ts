import { ActionFn, BlockEvent, Context, Event } from "@tenderly/actions";
import {
  Order,
  OrderBalance,
  OrderKind,
  computeOrderUid,
} from "@cowprotocol/contracts";

import axios from "axios";

import { ethers } from "ethers";
import { BytesLike, Logger } from "ethers/lib/utils";

import { ComposableCoW, ComposableCoW__factory } from "./types";
import {
  formatStatus,
  handleExecutionError,
  init,
  writeRegistry,
} from "./utils";
import { ChainContext, ConditionalOrder, OrderStatus } from "./model";
import { GPv2Order } from "./types/ComposableCoW";

const GPV2SETTLEMENT = "0x9008D19f58AAbD9eD0D60971565AA8510560ab41";

/**
 * Watch for new blocks and check for orders to place
 *
 * @param context tenderly context
 * @param event block event
 */
export const checkForAndPlaceOrder: ActionFn = async (
  context: Context,
  event: Event
) => {
  return _checkForAndPlaceOrder(context, event).catch(handleExecutionError);
};

/**
 * Asyncronous version of checkForAndPlaceOrder. It will process all the orders, and will throw an error at the end if there was at least one error
 */
const _checkForAndPlaceOrder: ActionFn = async (
  context: Context,
  event: Event
) => {
  const blockEvent = event as BlockEvent;
  const { network } = blockEvent;
  const chainContext = await ChainContext.create(context, network);
  const { registry } = await init(
    "checkForAndPlaceOrder",
    blockEvent.network,
    context
  );
  const { ownerOrders } = registry;

  // enumerate all the owners
  let hasErrors = false;
  console.log(`[checkForAndPlaceOrder] New Block ${blockEvent.blockNumber}`);
  for (const [owner, conditionalOrders] of ownerOrders.entries()) {
    const ordersPendingDelete = [];
    // enumerate all the `ConditionalOrder`s for a given owner
    for (const conditionalOrder of conditionalOrders) {
      console.log(
        `[checkForAndPlaceOrder] Check conditional order created in TX ${conditionalOrder.tx} with params:`,
        conditionalOrder.params
      );
      const contract = ComposableCoW__factory.connect(
        conditionalOrder.composableCow,
        chainContext.provider
      );

      const { deleteConditionalOrder, error } = await _processConditionalOrder(
        owner,
        network,
        conditionalOrder,
        contract,
        chainContext,
        context
      );

      hasErrors ||= error;

      if (deleteConditionalOrder) {
        ordersPendingDelete.push(conditionalOrder);
      }
    }

    ordersPendingDelete.forEach((conditionalOrder) => {
      const deleted = conditionalOrders.delete(conditionalOrder);
      const action = deleted ? "Deleted" : "Fail to delete";
      console.log(
        `[checkForAndPlaceOrder] ${action} conditional order with params:`,
        conditionalOrder.params
      );
    });
  }

  // Update the registry
  hasErrors ||= await !writeRegistry();

  // Throw execution error if there was at least one error
  if (hasErrors) {
    throw Error(
      "[checkForAndPlaceOrder] Error while checking if conditional orders are ready to be placed in Orderbook API"
    );
  }
};

async function _processConditionalOrder(
  owner: string,
  network: string,
  conditionalOrder: ConditionalOrder,
  contract: ComposableCoW,
  chainContext: ChainContext,
  context: Context
): Promise<{ deleteConditionalOrder: boolean; error: boolean }> {
  let error = false;
  try {
    const tradeableOrderResult = await _getTradeableOrderWithSignature(
      owner,
      conditionalOrder,
      contract
    );

    // Return early if the simulation fails
    if (tradeableOrderResult.result != CallResult.Success) {
      const { deleteConditionalOrder, result } = tradeableOrderResult;
      return {
        error: result !== CallResult.FailedButIsExpected, // If we expected the call to fail, then we don't consider it an error
        deleteConditionalOrder,
      };
    }

    const { order, signature } = tradeableOrderResult.data;

    const orderToSubmit: Order = {
      ...order,
      kind: kindToString(order.kind),
      sellTokenBalance: balanceToString(order.sellTokenBalance),
      buyTokenBalance: balanceToString(order.buyTokenBalance),
    };

    // calculate the orderUid
    const orderUid = _getOrderUid(network, orderToSubmit, owner);

    // if the orderUid has not been submitted, or filled, then place the order
    if (!conditionalOrder.orders.has(orderUid)) {
      await _placeOrder(
        orderUid,
        { ...orderToSubmit, from: owner, signature },
        chainContext.api_url
      );

      conditionalOrder.orders.set(orderUid, OrderStatus.SUBMITTED);
    } else {
      const orderStatus = conditionalOrder.orders.get(orderUid);
      console.log(
        `OrderUid ${orderUid} status: ${
          orderStatus ? formatStatus(orderStatus) : "Not found"
        }`
      );
    }
  } catch (e: any) {
    console.error(`Unexpected error while processing order:`, e);
  }

  return { deleteConditionalOrder: false, error };
}

function _getOrderUid(network: string, orderToSubmit: Order, owner: string) {
  return computeOrderUid(
    {
      name: "Gnosis Protocol",
      version: "v2",
      chainId: network,
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
}

/**
 * Print a list of all the orders that were placed and not filled
 *
 * @param orders All the orders that are being tracked
 */
export const _printUnfilledOrders = (orders: Map<BytesLike, OrderStatus>) => {
  const unfilledOrders = Array.from(orders.entries())
    .filter(([_orderUid, status]) => status === OrderStatus.SUBMITTED) // as SUBMITTED != FILLED
    .map(([orderUid, _status]) => orderUid)
    .join(", ");

  if (unfilledOrders) {
    console.log(`Unfilled Orders: `, unfilledOrders);
  }
};

/**
 * Place a new order
 * @param order to be placed on the cow protocol api
 * @param apiUrl rest api url
 */
async function _placeOrder(
  orderUid: string,
  order: any,
  apiUrl: string
): Promise<void> {
  try {
    const postData = {
      sellToken: order.sellToken,
      buyToken: order.buyToken,
      receiver: order.receiver,
      sellAmount: order.sellAmount.toString(),
      buyAmount: order.buyAmount.toString(),
      validTo: order.validTo,
      appData: order.appData,
      feeAmount: order.feeAmount.toString(),
      kind: order.kind,
      partiallyFillable: order.partiallyFillable,
      sellTokenBalance: order.sellTokenBalance,
      buyTokenBalance: order.buyTokenBalance,
      signingScheme: "eip1271",
      signature: order.signature,
      from: order.from,
    };

    // if the apiUrl doesn't contain localhost, post
    console.log(`[placeOrder] Post order ${orderUid} to ${apiUrl}`);
    console.log(`[placeOrder] Order`, postData);
    if (!apiUrl.includes("localhost")) {
      const { status, data } = await axios.post(
        `${apiUrl}/api/v1/orders`,
        postData,
        {
          headers: {
            "Content-Type": "application/json",
            accept: "application/json",
          },
        }
      );
      console.log(`[placeOrder] API response`, { status, data });
    }
  } catch (error: any) {
    const errorMessage = "[placeOrder] Error placing order in API";
    if (error.response) {
      const { status, data } = error.response;

      const { shouldThrow } = _handleOrderBookError(status, data);

      // The request was made and the server responded with a status code
      // that falls out of the range of 2xx
      const log = console[shouldThrow ? "error" : "warn"];
      log(`${errorMessage}. Result: ${status}`, data);

      if (!shouldThrow) {
        log("All good! continuing with warnings...");
        return;
      }
    } else if (error.request) {
      // The request was made but no response was received
      // `error.request` is an instance of XMLHttpRequest in the browser and an instance of
      // http.ClientRequest in node.js
      console.error(`${errorMessage}. Unresponsive API: ${error.request}`);
    } else if (error.message) {
      // Something happened in setting up the request that triggered an Error
      console.error(`${errorMessage}. Internal Error: ${error.message}`);
    } else {
      console.error(`${errorMessage}. Unhandled Error: ${error.message}`);
    }
    throw error;
  }
}

function _handleOrderBookError(
  status: any,
  data: any
): { shouldThrow: boolean } {
  if (status === 400 && data?.errorType === "DuplicatedOrder") {
    // The order is in the OrderBook, all good :)
    return { shouldThrow: false };
  }

  return { shouldThrow: true };
}

type GetTradeableOrderWithSignatureResult =
  | GetTradeableOrderWithSignatureSuccess
  | GetTradeableOrderWithSignatureError;

enum CallResult {
  Success,
  Failed,
  FailedButIsExpected,
}

type GetTradeableOrderWithSignatureSuccess = {
  result: CallResult.Success;
  deleteConditionalOrder: boolean;
  data: {
    order: GPv2Order.DataStructOutput;
    signature: string;
  };
};
type GetTradeableOrderWithSignatureError = {
  result: CallResult.Failed | CallResult.FailedButIsExpected;
  deleteConditionalOrder: boolean;
  errorObj: any;
};

async function _getTradeableOrderWithSignature(
  owner: string,
  conditionalOrder: ConditionalOrder,
  contract: ComposableCoW
): Promise<GetTradeableOrderWithSignatureResult> {
  const proof = conditionalOrder.proof ? conditionalOrder.proof.path : [];
  const offchainInput = "0x";
  const { to, data } =
    await contract.populateTransaction.getTradeableOrderWithSignature(
      owner,
      conditionalOrder.params,
      offchainInput,
      proof
    );

  console.log("[getTradeableOrderWithSignature] Simulate", {
    to,
    data,
  });

  try {
    const data = await contract.callStatic.getTradeableOrderWithSignature(
      owner,
      conditionalOrder.params,
      offchainInput,
      proof
    );

    return { result: CallResult.Success, deleteConditionalOrder: false, data };
  } catch (error: any) {
    // Print and handle the error
    // We need to decide if the error is final or not (if a re-attempt might help). If it doesn't, we delete the order
    const { result, deleteConditionalOrder } = _handleGetTradableOrderCall(
      error,
      owner
    );
    return {
      result,
      deleteConditionalOrder,
      errorObj: error,
    };
  }
}

function _handleGetTradableOrderCall(
  error: any,
  owner: string
): {
  result: CallResult.Failed | CallResult.FailedButIsExpected;
  deleteConditionalOrder: boolean;
} {
  if (error.code === Logger.errors.CALL_EXCEPTION) {
    const errorMessagePrefix =
      "[getTradeableOrderWithSignature] Call Exception";
    switch (error.errorName) {
      case "OrderNotValid":
        // The conditional order has not expired, or been cancelled, but the order is not valid
        // For example, with TWAPs, this may be after `span` seconds have passed in the epoch.
        return {
          result: CallResult.FailedButIsExpected,
          deleteConditionalOrder: false,
        };
      case "SingleOrderNotAuthed":
        // If there's no authorization we delete the order
        // - One reason could be, because the user CANCELLED the order
        // - for now it doesn't support more advanced cases where the order is auth during a pre-interaction

        console.info(
          `${errorMessagePrefix}: Single order on safe ${owner} not authed. Deleting order...`
        );
        return {
          result: CallResult.FailedButIsExpected,
          deleteConditionalOrder: true,
        };
      case "ProofNotAuthed":
        // If there's no authorization we delete the order
        // - One reason could be, because the user CANCELLED the order
        // - for now it doesn't support more advanced cases where the order is auth during a pre-interaction

        console.info(
          `${errorMessagePrefix}: Proof on safe ${owner} not authed. Deleting order...`
        );
        return {
          result: CallResult.FailedButIsExpected,
          deleteConditionalOrder: true,
        };
    }

    console.error(errorMessagePrefix + " for unexpected reasons", error);
    // If we don't know the reason, is better to not delete the order
    return { result: CallResult.Failed, deleteConditionalOrder: false };
  }

  console.error("[getTradeableOrderWithSignature] Unexpected error", error);
  // If we don't know the reason, is better to not delete the order
  return { result: CallResult.Failed, deleteConditionalOrder: false };
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
    return OrderKind.SELL;
  } else if (
    kind ===
    "0x6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc"
  ) {
    return OrderKind.BUY;
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
    return OrderBalance.ERC20;
  } else if (
    balance ===
    "0xabee3b73373acd583a130924aad6dc38cfdc44ba0555ba94ce2ff63980ea0632"
  ) {
    return OrderBalance.EXTERNAL;
  } else if (
    balance ===
    "0x4ac99ace14ee0a5ef932dc609df0943ab7ac16b7583634612f8dc35a4289a6ce"
  ) {
    return OrderBalance.INTERNAL;
  } else {
    throw new Error(`Unknown balance type: ${balance}`);
  }
};
