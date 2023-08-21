import assert = require("assert");
import Slack = require("node-slack");
import { Context } from "@tenderly/actions";

import { ethers } from "ethers";
import { ConnectionInfo, Logger } from "ethers/lib/utils";

import {
  init as sentryInit,
  startTransaction as sentryStartTransaction,
  Transaction as SentryTransaction,
} from "@sentry/node";
import { CaptureConsole as CaptureConsoleIntegration } from "@sentry/integrations";

import { ExecutionContext, OrderStatus, Registry } from "./model";

// const TENDERLY_LOG_LIMIT = 3800; // 4000 is the limit, we just leave some margin for printing the chunk index
const NOTIFICATION_WAIT_PERIOD = 1000 * 60 * 60 * 2; // 2h - Don't send more than one notification every 2h

let executionContext: ExecutionContext | undefined;

export async function init(
  transactionName: string,
  network: string,
  context: Context
): Promise<ExecutionContext> {
  // Init registry
  const registry = await Registry.load(context, network);

  // Get notifications config (enabled by default)
  const notificationsEnabled = await _getNotificationsEnabled(context);

  // Init slack
  const slack = await _getSlack(notificationsEnabled, context);

  // Init Sentry
  const sentryTransaction = await _getSentry(transactionName, network, context);
  if (!sentryTransaction) {
    console.warn("SENTRY_DSN secret is not set. Sentry will be disabled");
  }

  executionContext = {
    registry,
    slack,
    sentryTransaction,
    notificationsEnabled,
    context,
  };

  return executionContext;
}

async function _getNotificationsEnabled(context: Context): Promise<boolean> {
  // Get notifications config (enabled by default)
  return context.secrets
    .get("NOTIFICATIONS_ENABLED")
    .then((value) => (value ? value !== "false" : true))
    .catch(() => true);
}

async function _getSlack(
  notificationsEnabled: boolean,
  context: Context
): Promise<Slack | undefined> {
  if (executionContext) {
    return executionContext?.slack;
  }

  // Init slack
  let slack;
  const webhookUrl = await context.secrets
    .get("SLACK_WEBHOOK_URL")
    .catch(() => "");
  if (!notificationsEnabled) {
    return undefined;
  }

  if (!webhookUrl) {
    throw new Error(
      "SLACK_WEBHOOK_URL secret is required when NOTIFICATIONS_ENABLED is true"
    );
  }

  return new Slack(webhookUrl);
}

async function _getSentry(
  transactionName: string,
  network: string,
  context: Context
): Promise<SentryTransaction | undefined> {
  // Init Sentry
  if (!executionContext) {
    const sentryDsn = await context.secrets.get("SENTRY_DSN").catch(() => "");
    sentryInit({
      dsn: sentryDsn,
      debug: false,
      tracesSampleRate: 1.0, // Capture 100% of the transactions. Consider reducing in production.
      integrations: [
        new CaptureConsoleIntegration({
          levels: ["error", "warn", "log", "info"],
        }),
      ],
      initialScope: {
        tags: {
          network,
        },
      },
    });
  }

  // Return transaction
  return sentryStartTransaction({
    name: transactionName,
    op: "action",
  });
}

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

export async function handleExecutionError(e: any) {
  try {
    const errorMessage = e?.message || "Unknown error";
    const notified = sendSlack(
      errorMessage +
        ". More info https://dashboard.tenderly.co/devcow/project/actions"
    );

    if (notified && executionContext) {
      executionContext.registry.lastNotifiedError = new Date();
      await writeRegistry();
    }
  } catch (error) {
    consoleOriginal.error("Error sending slack notification", error);
  }

  // Re-throws the original error
  throw e;
}

/**
 * Utility function to handle promise, so they are logged in case of an error. It will return a promise that resolves to true if the promise is successful
 * @param errorMessage message to log in case of an error (together with the original error)
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
      console.error(errorMessage, error);
      return false;
    });
}

/**
 * Convenient utility to log in case theres an error writing in the registry and return a boolean with the result of the operation
 *
 * @param registry Tenderly registry
 * @returns a promise that returns true if the registry write was successful
 */
export async function writeRegistry(): Promise<boolean> {
  if (executionContext) {
    return handlePromiseErrors(
      "Error writing registry",
      executionContext.registry.write()
    );
  }

  return true;
}

var consoleOriginal = {
  log: console.log,
  error: console.error,
  warn: console.warn,
  debug: console.debug,
};

// TODO: Delete this code after we sort out the Tenderly log limit issue
// /**
//  * Tenderly has a limit of 4Kb per log message. When you surpass this limit, the log is not printed any more making it super hard to debug anything
//  *
//  * This tool will print
//  *
//  * @param data T
//  */
// const logWithLimit =
//   (level: "log" | "warn" | "error" | "debug") =>
//   (...data: any[]) => {
//     const bigLogText = data
//       .map((item) => {
//         if (typeof item === "string") {
//           return item;
//         }
//         return JSON.stringify(item, null, 2);
//       })
//       .join(" ");

//     const numChunks = Math.ceil(bigLogText.length / TENDERLY_LOG_LIMIT);

//     for (let i = 0; i < numChunks; i += 1) {
//       const chartStart = i * TENDERLY_LOG_LIMIT;
//       const prefix = numChunks > 1 ? `[${i + 1}/${numChunks}] ` : "";
//       const message =
//         prefix +
//         bigLogText.substring(chartStart, chartStart + TENDERLY_LOG_LIMIT);
//       consoleOriginal[level](message);

//       // if (level === "error") {
//       //   sendSlack(message);
//       // }

//       // // Used to debug the Tenderly log Limit issues
//       // consoleOriginal[level](
//       //   prefix + "TEST for bigLogText of " + bigLogText.length + " bytes"
//       // );
//     }
//   };

// Override the log function since some internal libraries might print something and breaks Tenderly

// console.warn = logWithLimit("warn");
// console.error = logWithLimit("error");
// console.debug = logWithLimit("debug");
// console.log = logWithLimit("log");

export function sendSlack(message: string): boolean {
  if (!executionContext) {
    consoleOriginal.warn(
      "[sendSlack] Slack not initialized, ignoring message",
      message
    );
    return false;
  }

  const { slack, registry, notificationsEnabled } = executionContext;

  // Do not notify IF notifications are disabled
  if (!notificationsEnabled || !slack) {
    return false;
  }

  if (registry.lastNotifiedError !== null) {
    const nextErrorNotificationTime =
      registry.lastNotifiedError.getTime() + NOTIFICATION_WAIT_PERIOD;
    if (Date.now() < nextErrorNotificationTime) {
      console.warn(
        `[sendSlack] Last error notification happened earlier than ${
          NOTIFICATION_WAIT_PERIOD / 60_000
        } minutes ago. Next notification will happen after ${new Date(
          nextErrorNotificationTime
        )}`
      );
      return false;
    }
  }

  slack.send({
    text: message,
  });
  return true;
}
