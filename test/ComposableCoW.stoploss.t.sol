// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order, IConditionalOrder, BaseComposableCoWTest} from "./ComposableCoW.base.t.sol";
import {IAggregatorV3Interface} from "../src/interfaces/IAggregatorV3Interface.sol";
import {StopLoss, STRIKE_NOT_REACHED, ORACLE_STALE_PRICE, ORACLE_INVALID_PRICE, ORDER_EXPIRED} from "../src/types/StopLoss.sol";

contract ComposableCoWStopLossTest is BaseComposableCoWTest {
    IERC20 immutable SELL_TOKEN = IERC20(address(0x1));
    IERC20 immutable BUY_TOKEN = IERC20(address(0x2));
    address constant SELL_ORACLE = address(0x3);
    address constant BUY_ORACLE = address(0x4);
    bytes32 constant APP_DATA = bytes32(0x0);

    uint8 constant DEFAULT_DECIMALS = 18;

    StopLoss stopLoss;
    address safe;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        stopLoss = new StopLoss();
    }

    function priceToAddress(int256 price) internal returns (address) {
        return address(uint160(int160(price)));
    }

    function mockOracle(address mock, int256 price, uint256 updatedAt, uint8 decimals)
        internal
        returns (IAggregatorV3Interface iface)
    {
        iface = IAggregatorV3Interface(mock);
        vm.mockCall(mock, abi.encodeWithSelector(iface.latestRoundData.selector), abi.encode(0, price, 0, updatedAt, 0));
        vm.mockCall(mock, abi.encodeWithSelector(iface.decimals.selector), abi.encode(decimals));
    }

    function mockToken(IERC20 token, uint8 decimals) internal returns (IERC20 iface) {
        iface = IERC20(token);
        vm.mockCall(address(token), abi.encodeWithSelector(iface.decimals.selector), abi.encode(decimals));
    }

    function test_strikePriceNotMet_concrete() public {
        // prevents underflow when checking for stale prices
        vm.warp(30 minutes);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS),
            buyToken: mockToken(BUY_TOKEN, DEFAULT_DECIMALS),
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, 200 ether, block.timestamp, DEFAULT_DECIMALS),
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, 100 ether, block.timestamp, DEFAULT_DECIMALS),
            strike: 1,
            sellAmount: 1 ether,
            buyAmount: 1 ether,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: false,
            isPartiallyFillable: false,
            validTo: type(uint32).max,
            maxTimeSinceLastOracleUpdate: 15 minutes
        });

        createOrder(stopLoss, 0x0, abi.encode(data));

        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalOrder.PollTryNextBlock.selector,
                STRIKE_NOT_REACHED
            )
        );
        stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
    }

    function test_RevertStrikePriceNotMet_fuzz(
        int256 sellTokenOraclePrice,
        int256 buyTokenOraclePrice,
        int256 strike,
        uint256 currentTime,
        uint256 staleTime
    ) public {
        vm.assume(buyTokenOraclePrice > 0);
        vm.assume(sellTokenOraclePrice > 0 && sellTokenOraclePrice <= type(int256).max / 10 ** 18);
        vm.assume(strike > 0);
        vm.assume(sellTokenOraclePrice * int256(10 ** 18) / buyTokenOraclePrice > strike);
        vm.assume(currentTime > staleTime);

        // guard against overflow
        vm.assume(currentTime < type(uint32).max);

        vm.warp(currentTime);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS),
            buyToken: mockToken(BUY_TOKEN, DEFAULT_DECIMALS),
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, sellTokenOraclePrice, block.timestamp, DEFAULT_DECIMALS),
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, buyTokenOraclePrice, block.timestamp, DEFAULT_DECIMALS),
            strike: strike,
            sellAmount: 1 ether,
            buyAmount: 1 ether,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: false,
            isPartiallyFillable: false,
            validTo: type(uint32).max,
            maxTimeSinceLastOracleUpdate: staleTime
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalOrder.PollTryNextBlock.selector,
                STRIKE_NOT_REACHED
            )
        );
        stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
    }

    function test_OracleNormalisesPrice_fuzz(
        uint8 sellTokenERC20Decimals,
        uint8 buyTokenERC20Decimals,
        uint8 sellTokenOracleDecimals,
        uint8 buyTokenOracleDecimals
    ) public {
        // guard against overflow.
        // given the use of the decimals in exponentiation, supporting type(uint8).max
        // is not possible as the result of the exponentiation would overflow uint256.
        // Most tokens have 18 decimals, though there is precendent for 45 decimals,
        // such as the use of `rad` in the MakerDAO system.
        vm.assume(sellTokenERC20Decimals <= 45);
        vm.assume(buyTokenERC20Decimals <= 45);
        vm.assume(sellTokenOracleDecimals <= 45);
        vm.assume(buyTokenOracleDecimals <= 45);

        vm.warp(1687718451);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, sellTokenERC20Decimals),
            buyToken: mockToken(BUY_TOKEN, buyTokenERC20Decimals),
            sellTokenPriceOracle: mockOracle(
                SELL_ORACLE, int256(1834 * (10 ** sellTokenOracleDecimals)), block.timestamp, sellTokenOracleDecimals
            ),
            buyTokenPriceOracle: mockOracle(
                BUY_ORACLE, int256(1 * (10 ** buyTokenOracleDecimals)), block.timestamp, buyTokenOracleDecimals
            ),
            strike: int256(
                1900
                    * (
                        sellTokenERC20Decimals > buyTokenERC20Decimals
                            ? (10 ** (sellTokenERC20Decimals - buyTokenERC20Decimals + 18))
                            : (10 ** (buyTokenERC20Decimals - sellTokenERC20Decimals + 18))
                    )
            ), // Strike price is to 18 decimals, base / quote. ie. 1900_000_000_000_000_000_000 = 1900 USDC/ETH
            sellAmount: 1 ether,
            buyAmount: 1,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: true,
            isPartiallyFillable: false,
            validTo: type(uint32).max,
            maxTimeSinceLastOracleUpdate: 15 minutes
        });

        GPv2Order.Data memory order =
            stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
        assertEq(address(order.sellToken), address(SELL_TOKEN));
        assertEq(address(order.buyToken), address(BUY_TOKEN));
        assertEq(order.sellAmount, 1 ether);
        assertEq(order.buyAmount, 1);
        assertEq(order.receiver, address(0x0));
        assertEq(order.validTo, type(uint32).max);
        assertEq(order.appData, APP_DATA);
        assertEq(order.feeAmount, 0);
        assertEq(order.kind, GPv2Order.KIND_SELL);
        assertEq(order.partiallyFillable, false);
        assertEq(order.sellTokenBalance, GPv2Order.BALANCE_ERC20);
        assertEq(order.buyTokenBalance, GPv2Order.BALANCE_ERC20);
    }

    function test_OracleNormalisesPrice_concrete() public {
        // 25 June 2023 18:40:51
        vm.warp(1687718451);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS), // simulate ETH (using the ETH/USD chainlink)
            buyToken: mockToken(BUY_TOKEN, 6), // simulate USDC (using the USDC/USD chainlink)
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, 183_449_235_095, block.timestamp, 8), // assume price is 1834.49235095 ETH/USD
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, 100_000_000, block.timestamp, 8), // assume 1:1 USDC:USD
            strike: 1900_000_000_000_000_000_000, // Strike price is base / quote to 18 decimals. ie. 1900_000_000_000_000_000_000 = 1900 USDC/ETH
            sellAmount: 1 ether,
            buyAmount: 1,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: true,
            isPartiallyFillable: false,
            validTo: type(uint32).max,
            maxTimeSinceLastOracleUpdate: 15 minutes
        });

        GPv2Order.Data memory order =
            stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
        assertEq(address(order.sellToken), address(SELL_TOKEN));
        assertEq(address(order.buyToken), address(BUY_TOKEN));
        assertEq(order.sellAmount, 1 ether);
        assertEq(order.buyAmount, 1);
        assertEq(order.receiver, address(0x0));
        assertEq(order.validTo, type(uint32).max);
        assertEq(order.appData, APP_DATA);
        assertEq(order.feeAmount, 0);
        assertEq(order.kind, GPv2Order.KIND_SELL);
        assertEq(order.partiallyFillable, false);
        assertEq(order.sellTokenBalance, GPv2Order.BALANCE_ERC20);
        assertEq(order.buyTokenBalance, GPv2Order.BALANCE_ERC20);
    }

    function test_OracleRevertOnStalePrice_fuzz(
        uint256 currentTime,
        uint256 maxTimeSinceLastOracleUpdate,
        uint256 updatedAt
    ) public {
        // guard against underflow
        vm.assume(currentTime > maxTimeSinceLastOracleUpdate);
        vm.assume(currentTime < type(uint32).max);
        // enforce stale price
        vm.assume(updatedAt < (currentTime - maxTimeSinceLastOracleUpdate));

        vm.warp(currentTime);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS),
            buyToken: mockToken(BUY_TOKEN, DEFAULT_DECIMALS),
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, 100 ether, updatedAt, DEFAULT_DECIMALS),
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, 100 ether, updatedAt, DEFAULT_DECIMALS),
            strike: 1,
            sellAmount: 1 ether,
            buyAmount: 1 ether,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: false,
            isPartiallyFillable: false,
            validTo: type(uint32).max,
            maxTimeSinceLastOracleUpdate: maxTimeSinceLastOracleUpdate
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalOrder.PollTryNextBlock.selector,
                ORACLE_STALE_PRICE
            )
        );
        stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
    }

    function test_OracleRevertOnInvalidPrice_fuzz(int256 invalidPrice, int256 validPrice) public {
        // enforce invalid price
        vm.assume(invalidPrice <= 0);
        vm.assume(validPrice > 0);

        vm.warp(30 minutes);

        // case where sell token price is invalid

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS),
            buyToken: mockToken(BUY_TOKEN, DEFAULT_DECIMALS),
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, invalidPrice, block.timestamp, DEFAULT_DECIMALS),
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, validPrice, block.timestamp, DEFAULT_DECIMALS),
            strike: 1,
            sellAmount: 1 ether,
            buyAmount: 1 ether,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: false,
            isPartiallyFillable: false,
            validTo: type(uint32).max,
            maxTimeSinceLastOracleUpdate: 15 minutes
        });

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, ORACLE_INVALID_PRICE));
        stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));

        // case where buy token price is invalid

        data.sellTokenPriceOracle = mockOracle(SELL_ORACLE, validPrice, block.timestamp, DEFAULT_DECIMALS);
        data.buyTokenPriceOracle = mockOracle(BUY_ORACLE, invalidPrice, block.timestamp, DEFAULT_DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.OrderNotValid.selector, ORACLE_INVALID_PRICE));
        stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
    }

    function test_OracleRevertOnExpiredOrder_fuzz(
        uint32 currentTime,
        uint32 validTo
    ) public {
        // enforce expired order
        vm.assume(currentTime > validTo);

        vm.warp(currentTime);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS),
            buyToken: mockToken(BUY_TOKEN, DEFAULT_DECIMALS),
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, 100 ether, block.timestamp, DEFAULT_DECIMALS),
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, 100 ether, block.timestamp, DEFAULT_DECIMALS),
            strike: 1,
            sellAmount: 1 ether,
            buyAmount: 1 ether,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: false,
            isPartiallyFillable: false,
            validTo: validTo,
            maxTimeSinceLastOracleUpdate: 15 minutes
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IConditionalOrder.OrderNotValid.selector,
                ORDER_EXPIRED
            )
        );
        stopLoss.getTradeableOrder(
            safe,
            address(0),
            bytes32(0),
            abi.encode(data),
            bytes("")
        );
    }

    function test_strikePriceMet_fuzz(
        int256 sellTokenOraclePrice,
        int256 buyTokenOraclePrice,
        int256 strike,
        uint32 validTo
    ) public {
        // 25 June 2023 18:40:51
        vm.warp(1687718451);

        vm.assume(validTo >= block.timestamp);
        vm.assume(buyTokenOraclePrice > 0);
        vm.assume(sellTokenOraclePrice > 0 && sellTokenOraclePrice <= type(int256).max / 10 ** 18);
        vm.assume(strike > 0);
        vm.assume(sellTokenOraclePrice * int256(10 ** 18) / buyTokenOraclePrice <= strike);

        StopLoss.Data memory data = StopLoss.Data({
            sellToken: mockToken(SELL_TOKEN, DEFAULT_DECIMALS),
            buyToken: mockToken(BUY_TOKEN, DEFAULT_DECIMALS),
            sellTokenPriceOracle: mockOracle(SELL_ORACLE, sellTokenOraclePrice, block.timestamp, DEFAULT_DECIMALS),
            buyTokenPriceOracle: mockOracle(BUY_ORACLE, buyTokenOraclePrice, block.timestamp, DEFAULT_DECIMALS),
            strike: strike,
            sellAmount: 1 ether,
            buyAmount: 1 ether,
            appData: APP_DATA,
            receiver: address(0x0),
            isSellOrder: false,
            isPartiallyFillable: false,
            validTo: validTo,
            maxTimeSinceLastOracleUpdate: 15 minutes
        });

        GPv2Order.Data memory order =
            stopLoss.getTradeableOrder(safe, address(0), bytes32(0), abi.encode(data), bytes(""));
        assertEq(address(order.sellToken), address(SELL_TOKEN));
        assertEq(address(order.buyToken), address(BUY_TOKEN));
        assertEq(order.sellAmount, 1 ether);
        assertEq(order.buyAmount, 1 ether);
        assertEq(order.receiver, address(0x0));
        assertEq(order.validTo, validTo);
        assertEq(order.appData, APP_DATA);
        assertEq(order.feeAmount, 0);
        assertEq(order.kind, GPv2Order.KIND_BUY);
        assertEq(order.partiallyFillable, false);
        assertEq(order.sellTokenBalance, GPv2Order.BALANCE_ERC20);
        assertEq(order.buyTokenBalance, GPv2Order.BALANCE_ERC20);
    }
}
