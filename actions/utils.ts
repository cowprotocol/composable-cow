import { Context } from "@tenderly/actions";
import assert = require("assert");

import { ethers } from "ethers";
import { ConnectionInfo, Logger } from "ethers/lib/utils";
import { OrderStatus } from "./register";

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
