// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";
import "../interfaces/IConditionalOrder.sol";
import "../BaseConditionalOrder.sol";

// --- error strings

/// @dev Invalid sell token asset
string constant INVALID_SELL_TOKEN = "invalid sell token";
/// @dev Invalid buy token asset
string constant INVALID_BUY_TOKEN = "invalid sell amount";
/// @dev Invalid receiver
string constant INVALID_RECEIVER = "invalid receiver";
/// @dev Invalid valid to timestamp
string constant INVALID_VALIDITY = "invalid validity";
/// @dev Either a buy order was attempted to be matched with a sell order or vice versa
string constant INVALID_ORDER_KIND = "invalid order kind";
/// @dev The limit price is not satisfied or the order is trying to be partially filled
string constant INVALID_LIMIT_AMOUNTS = "invalid limit amounts";
/// @dev Only ERC20 balances are supported
string constant INVALID_BALANCE = "invalid balances";

/**
 * @title Limit order
 * Providing tokens, limit amounts and a recipient, this conditional order type will accept any fill-or-kill trade satisfying these parameters until a certain deadline.
 * @dev This order type does not have any replay protection, meaning it may be triggered many times assuming the contract has sufficient funds.
 */
contract LimitOrder is IConditionalOrder {
  /**
   * Defines the parameters of the limit order
   * @param sellToken: the token to be sold
   * @param buyToken: the token to be bought
   * @param sellAmount: In case of a sell order, the exact amount of tokens the order is willing to sell. In case of a buy order, the maximium amount of tokens it is willing to sell
   * @param buyAmount: In case of a sell order, the min amount of tokens the order is wants to receive. In case of a buy order, the exact amount of tokens it is willing to receive
   * @param receiver: The account that should receive the proceeds of the trade
   * @param validTo: The timestamp (in unix epoch) until which the order is valid
   * @param isSellOrder: Whether this is a sell or buy order
   */
  struct Data {
    IERC20 sellToken;
    IERC20 buyToken;
    uint256 sellAmount;
    uint256 buyAmount;
    address receiver;
    uint32 validTo;
    bool isSellOrder;
  }

  /**
   * @dev Check if the suggested order satisfies the limit order parameters.
   */
  function verify(
    address,
    address,
    bytes32 hash,
    bytes32 domainSeparator,
    bytes32,
    bytes calldata staticInput,
    bytes calldata,
    GPv2Order.Data calldata suggestedOrder
  ) external pure override {
    /// @dev Verify that the *suggested* order matches the payload.
    if (!(hash == GPv2Order.hash(suggestedOrder, domainSeparator))) {
      revert IConditionalOrder.OrderNotValid(INVALID_HASH);
    }

    Data memory limitOrder = abi.decode(staticInput, (Data));

    /// Verify order parameters
    if (suggestedOrder.sellToken != limitOrder.sellToken) {
      revert IConditionalOrder.OrderNotValid(INVALID_SELL_TOKEN);
    }

    if (suggestedOrder.buyToken != limitOrder.buyToken) {
      revert IConditionalOrder.OrderNotValid(INVALID_BUY_TOKEN);
    }

    if (suggestedOrder.receiver != limitOrder.receiver) {
      revert IConditionalOrder.OrderNotValid(INVALID_RECEIVER);
    }

    if (suggestedOrder.validTo > limitOrder.validTo) {
      revert IConditionalOrder.OrderNotValid(INVALID_VALIDITY);
    }

    if (suggestedOrder.kind == GPv2Order.KIND_SELL) {
      if (!limitOrder.isSellOrder) {
        revert IConditionalOrder.OrderNotValid(INVALID_ORDER_KIND);
      }
      if (
        (suggestedOrder.sellAmount + suggestedOrder.feeAmount) !=
        limitOrder.sellAmount
      ) {
        revert IConditionalOrder.OrderNotValid(INVALID_LIMIT_AMOUNTS);
      }
      if (suggestedOrder.buyAmount < limitOrder.buyAmount) {
        revert IConditionalOrder.OrderNotValid(INVALID_LIMIT_AMOUNTS);
      }
    } else {
      // BUY order
      if (limitOrder.isSellOrder) {
        revert IConditionalOrder.OrderNotValid(INVALID_ORDER_KIND);
      }
      if (
        (suggestedOrder.sellAmount + suggestedOrder.feeAmount) >
        limitOrder.sellAmount
      ) {
        revert IConditionalOrder.OrderNotValid(INVALID_LIMIT_AMOUNTS);
      }
      if (suggestedOrder.buyAmount != limitOrder.buyAmount) {
        revert IConditionalOrder.OrderNotValid(INVALID_LIMIT_AMOUNTS);
      }
    }

    if (
      suggestedOrder.buyTokenBalance != GPv2Order.BALANCE_ERC20 ||
      suggestedOrder.sellTokenBalance != GPv2Order.BALANCE_ERC20
    ) {
      revert IConditionalOrder.OrderNotValid(INVALID_BALANCE);
    }
  }
}
