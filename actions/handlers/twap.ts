import { TWAP_ADDRESS } from "@cowprotocol/cow-sdk";

import { SmartOrderValidator, ValidationResult } from "../model";

export const handlerAddress = TWAP_ADDRESS;

export const validateOrder: SmartOrderValidator = async (_params) => {
  // TODO: Implement validation logic, ideally delegate to the SDK

  return {
    result: ValidationResult.Success,
    data: undefined,
  };
};
