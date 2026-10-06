// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";
import "./ComposableCoW.base.t.sol";
import "../src/types/LimitOrder.sol";

library LimitOrderTest {
  bytes32 constant DOMAIN_SEPARATOR =
    0x3fd54831f488a22b28398de0c567a3b064b937f54f81739ae9bd545967f3abab;

  function fail(
    LimitOrder order,
    Vm vm,
    LimitOrder.Data memory orderData,
    GPv2Order.Data memory trade,
    string memory reason
  ) internal {
    vm.expectRevert(
      abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, reason)
    );
    order.verify(
      address(0),
      address(0),
      GPv2Order.hash(trade, DOMAIN_SEPARATOR),
      DOMAIN_SEPARATOR,
      bytes32(0),
      abi.encode(orderData),
      bytes(""),
      trade
    );
  }

  function pass(
    LimitOrder order,
    LimitOrder.Data memory orderData,
    GPv2Order.Data memory trade
  ) internal pure {
    order.verify(
      address(0),
      address(0),
      GPv2Order.hash(trade, DOMAIN_SEPARATOR),
      DOMAIN_SEPARATOR,
      bytes32(0),
      abi.encode(orderData),
      bytes(""),
      trade
    );
  }
}

contract ComposableCoWLimitOrderTest is Test {
  IERC20 immutable SELL_TOKEN = IERC20(address(0x1));
  IERC20 immutable BUY_TOKEN = IERC20(address(0x2));
  address constant RECEIVER = address(0x3);
  uint32 constant VALID_TO = 1687718700;

  using LimitOrderTest for LimitOrder;

  LimitOrder.Data sell;
  LimitOrder.Data buy;

  function setUp() public virtual {
    sell = LimitOrder.Data({
      sellToken: SELL_TOKEN,
      buyToken: BUY_TOKEN,
      sellAmount: 1 ether,
      buyAmount: 1 ether,
      receiver: RECEIVER,
      validTo: VALID_TO,
      isSellOrder: true
    });
    buy = LimitOrder.Data({
      sellToken: SELL_TOKEN,
      buyToken: BUY_TOKEN,
      sellAmount: 1 ether,
      buyAmount: 1 ether,
      receiver: RECEIVER,
      validTo: VALID_TO,
      isSellOrder: false
    });
  }

  function valid_trade(
    bytes32 kind
  ) public view returns (GPv2Order.Data memory) {
    return
      GPv2Order.Data(
        SELL_TOKEN,
        BUY_TOKEN,
        RECEIVER,
        1 ether,
        1 ether,
        VALID_TO,
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
        0, // use zero fee for limit orders
        kind,
        false,
        GPv2Order.BALANCE_ERC20,
        GPv2Order.BALANCE_ERC20
      );
  }

  function test_valid_order() public {
    LimitOrder order = new LimitOrder();
    GPv2Order.Data memory valid = valid_trade(GPv2Order.KIND_SELL);
    order.pass(sell, valid);

    valid.kind = GPv2Order.KIND_BUY;
    order.pass(buy, valid);
  }

  function test_amounts_sell_order() public {
    LimitOrder order = new LimitOrder();
    GPv2Order.Data memory valid = valid_trade(GPv2Order.KIND_SELL);

    // Higer buy amount allowed for sell orders
    valid.buyAmount += 1;
    order.pass(sell, valid);

    // Lower buy amount not allowed
    valid.buyAmount -= 2;
    order.fail(vm, sell, valid, INVALID_LIMIT_AMOUNTS);

    // Different sell amount not allowed
    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.sellAmount += 1;
    order.fail(vm, sell, valid, INVALID_LIMIT_AMOUNTS);

    valid.sellAmount -= 2;
    order.fail(vm, sell, valid, INVALID_LIMIT_AMOUNTS);
  }

  function test_amounts_buy_order() public {
    LimitOrder order = new LimitOrder();
    GPv2Order.Data memory valid = valid_trade(GPv2Order.KIND_BUY);

    // Lower sell amount allowed for buy orders
    valid.sellAmount -= 1;
    order.pass(buy, valid);

    // Higher sell amount not allowed
    valid.sellAmount += 2;
    order.fail(vm, buy, valid, INVALID_LIMIT_AMOUNTS);

    // Different buy amount not allowed
    valid = valid_trade(GPv2Order.KIND_BUY);
    valid.buyAmount += 1;
    order.fail(vm, buy, valid, INVALID_LIMIT_AMOUNTS);

    valid.buyAmount -= 2;
    order.fail(vm, buy, valid, INVALID_LIMIT_AMOUNTS);
  }

  function test_amounts_fee() public {
    LimitOrder order = new LimitOrder();
    GPv2Order.Data memory valid = valid_trade(GPv2Order.KIND_SELL);

    // Fee exceeds amount
    valid.feeAmount = 0.1 ether;
    order.fail(vm, sell, valid, INVALID_LIMIT_AMOUNTS);

    // Can be taken from sell amount
    valid.sellAmount -= 0.1 ether;
    order.pass(sell, valid);

    // Same for buy orders
    valid = valid_trade(GPv2Order.KIND_BUY);
    valid.feeAmount = 0.1 ether;
    order.fail(vm, buy, valid, INVALID_LIMIT_AMOUNTS);

    valid.sellAmount -= 0.1 ether;
    order.pass(buy, valid);

    // Smaller fee is allowed for buy orders
    valid.feeAmount = 0.01 ether;
    order.pass(buy, valid);
  }

  function test_invalid_preimage() public {
    LimitOrder order = new LimitOrder();
    GPv2Order.Data memory valid = valid_trade(GPv2Order.KIND_SELL);
    bytes32 invalid_hash = GPv2Order.hash(
      valid,
      LimitOrderTest.DOMAIN_SEPARATOR
    );

    // Changing something about the preimage makes it no longer correspond to the hash
    valid.appData = keccak256("other data");

    vm.expectRevert(
      abi.encodeWithSelector(
        IConditionalOrder.OrderNotValid.selector,
        INVALID_HASH
      )
    );
    order.verify(
      address(0),
      address(0),
      invalid_hash,
      LimitOrderTest.DOMAIN_SEPARATOR,
      bytes32(0),
      abi.encode(sell),
      bytes(""),
      valid
    );
  }

  function test_params() public {
    LimitOrder order = new LimitOrder();
    GPv2Order.Data memory valid = valid_trade(GPv2Order.KIND_SELL);

    // Any app data is allowed
    valid.appData = keccak256("other data");
    order.pass(sell, valid);

    // Earlier validTo is allowed
    valid.validTo -= 1;
    order.pass(sell, valid);

    // Later validTo is not allowed
    valid.validTo += 2;
    order.fail(vm, sell, valid, INVALID_VALIDITY);

    // Different balance is not allowed
    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.sellTokenBalance = GPv2Order.BALANCE_EXTERNAL;
    order.fail(vm, sell, valid, INVALID_BALANCE);

    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.buyTokenBalance = GPv2Order.BALANCE_EXTERNAL;
    order.fail(vm, sell, valid, INVALID_BALANCE);

    // Different kind is not allowed
    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.kind = GPv2Order.KIND_BUY;
    order.pass(buy, valid);
    order.fail(vm, sell, valid, INVALID_ORDER_KIND);

    valid.kind = GPv2Order.KIND_SELL;
    order.pass(sell, valid);
    order.fail(vm, buy, valid, INVALID_ORDER_KIND);

    // Different receiver is not allowed
    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.receiver = address(0xdeadbeef);
    order.fail(vm, sell, valid, INVALID_RECEIVER);

    // Different sell token is not allowed
    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.sellToken = IERC20(address(0xdeadbeef));
    order.fail(vm, sell, valid, INVALID_SELL_TOKEN);

    // Different buy token is not allowed
    valid = valid_trade(GPv2Order.KIND_SELL);
    valid.buyToken = IERC20(address(0xdeadbeef));
    order.fail(vm, sell, valid, INVALID_BUY_TOKEN);
  }
}
