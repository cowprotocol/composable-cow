import {
  SmartOrderValidationResult,
  SmartOrderValidator,
  ValidateOrderParams,
} from "../model";

import {
  handlerAddress as handlerTwap,
  validateOrder as validateOrderTwap,
} from "./twap";

const validatorsForHandler: Record<string, SmartOrderValidator> = {
  [handlerTwap.toLowerCase()]: validateOrderTwap,
};

/**
 * Validate a smart order using the custom handler logic (if known)
 *
 * @returns The result of the validation if the handler is known, undefined otherwise
 */
export async function validateOrder(
  params: ValidateOrderParams
): Promise<SmartOrderValidationResult<void> | undefined> {
  const { handler } = params;
  const validateFn = validatorsForHandler[handler.toLowerCase()];
  return validateFn ? validateFn(params) : undefined;
}
