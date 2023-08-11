import { Context } from "@tenderly/actions";
import assert = require("assert");

import { ethers } from "ethers";
import { ConnectionInfo, Logger } from "ethers/lib/utils";
import { OrderStatus, Registry } from "./register";

const TENDERLY_LOG_LIMIT = 3800; // 4000 is the limit, we just leave some margin for printing the chunk index

async function getSecret(key: string, context: Context): Promise<string> {
  const value = await context.secrets.get(key);
  assert(value, `${key} secret is required`);

  return value;
}

export async function getProvider(
  context: Context,
  network: string
): Promise<ethers.providers.Provider> {
  Logger.setLogLevel(Logger.levels.DEBUG);

  const url = await getSecret(`NODE_URL_${network}`, context);
  const user = await getSecret(`NODE_USER_${network}`, context).catch(
    () => undefined
  );
  const password = await getSecret(`NODE_PASSWORD_${network}`, context).catch(
    () => undefined
  );
  const providerConfig: ConnectionInfo =
    user && password
      ? {
          url,
          // TODO: This is a hack to make it work for HTTP endpoints (while we don't have a HTTPS one for Gnosis Chain), however I will delete once we have it
          headers: {
            Authorization: getAuthHeader({ user, password }),
          },
          // user: await getSecret(`NODE_USER_${network}`, context),
          // password: await getSecret(`NODE_PASSWORD_${network}`, context),
        }
      : { url };

  return new ethers.providers.JsonRpcProvider(providerConfig);
}

function getAuthHeader({ user, password }: { user: string; password: string }) {
  return "Basic " + Buffer.from(`${user}:${password}`).toString("base64");
}

export function apiUrl(network: string): string {
  switch (network) {
    case "1":
      return "https://api.cow.fi/mainnet";
    case "5":
      return "https://api.cow.fi/goerli";
    case "100":
      return "https://api.cow.fi/xdai";
    case "31337":
      return "http://localhost:3000";
    default:
      throw "Unsupported network";
  }
}

export function formatStatus(status: OrderStatus) {
  switch (status) {
    case OrderStatus.FILLED:
      return "FILLED";
    case OrderStatus.SUBMITTED:
      return "SUBMITTED";
    default:
      return `UNKNOWN (${status})`;
  }
}

/**
 * Utility function to handle promise, so they are logged in case of an error. It will return a promise that resolves to true if the promise is successful
 * @param errorMessage message to log in case of an error (together witht he original error)
 * @param promise original promise
 * @returns a promise that returns true if the original promise was successful
 */
function handlePromiseErrors<T>(
  errorMessage: string,
  promise: Promise<T>
): Promise<boolean> {
  return promise
    .then(() => true)
    .catch((error) => {
      console.error(errorMessage, error /*extractErrorMessage(error)*/);
      return true;
    });
}

/**
 * Convenient utility to log in case theres an error writing in the registry
 * @param registry Tenderly registry
 * @returns a promise that returns true if the registry write was successful
 */
export function writeRegistry(registry: Registry): Promise<boolean> {
  return handlePromiseErrors("Error writing registry", registry.write());
}

// /**
//  * This util should not be needed, but tenderly has some annoying issues with the logs. They hide important logs, leaving us blind
//  * I suspect, some of them is because we print errors which contain a tacktrace, and they think this is too big og a message
//  *
//  * Ideally this util shold not be used, ands we shoudl print the whole error
//  *
//  * @param obj
//  * @returns
//  */
// export function extractErrorMessage(error: unknown): string {
//   if (isErrorWithMesage(error)) {
//     return error.message;
//   }

//   return "";
// }

// function isErrorWithMesage(obj: unknown): obj is { message: string } {
//   return (
//     typeof obj === "object" && obj !== null && "name" in obj && "age" in obj
//   );
// }

/**
 * Tenderly has a limit of 4Kb per log message. When you surpas this limit, the log is not printed any more making it super hard to debug anythnig
 *
 * This tool will print
 *
 * @param data T
 */
const logWithLimit =
  (level: "log" | "warn" | "error" | "debug") =>
  (...data: any[]) => {
    const bigLogText = data
      .map((item) => {
        if (typeof item === "string") {
          return item;
        }
        return JSON.stringify(item, null, 2);
      })
      .join(" ");

    const numChunks = Math.ceil(bigLogText.length / TENDERLY_LOG_LIMIT);

    for (let i = 0; i < numChunks; i += 1) {
      const chartStart = i * TENDERLY_LOG_LIMIT;
      const prefix = numChunks > 1 ? `[${i + 1}/${numChunks}] ` : "";
      console[level](
        prefix +
          bigLogText.substring(chartStart, chartStart + TENDERLY_LOG_LIMIT)
      );
    }
  };

export const logger = {
  error: logWithLimit("warn"),
  warn: logWithLimit("error"),
  debug: logWithLimit("debug"),
  log: logWithLimit("log"),
};
