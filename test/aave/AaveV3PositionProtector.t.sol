// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {PercentageMath} from "aave-v3-origin/contracts/protocol/libraries/math/PercentageMath.sol";
import {GPv2AllowListAuthentication} from "cowprotocol/contracts/GPv2AllowListAuthentication.sol";
import {GPv2Settlement, GPv2Interaction, IERC20} from "cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2Order, GPv2Trade, GPv2Signing} from "cowprotocol/contracts/GPv2Settlement.sol";

import {FlashLoanRouter, Loan} from "../../lib/flash-loan-router/src/FlashLoanRouter.sol";
import {ICowSettlement, IBorrower} from "../../lib/flash-loan-router/src/interface/IBorrower.sol";
import {IERC20 as RouterToken} from "../../lib/flash-loan-router/src/vendored/IERC20.sol";
import {AavePositionProtectionHandler} from "../../src/aave/AavePositionProtectionHandler.sol";
import {AaveV3PositionProtector} from "../../src/aave/AaveV3PositionProtector.sol";
import {IAavePositionProtector} from "../../src/aave/interfaces/IAavePositionProtector.sol";
import {ComposableCoW} from "../../src/ComposableCoW.sol";
import {IConditionalOrder} from "../../src/interfaces/IConditionalOrder.sol";
import {CoWProtocol} from "../helpers/CoWProtocol.t.sol";
import {GPv2TradeEncoder} from "../vendored/GPv2TradeEncoder.sol";

contract RoundedAToken is ERC20Mock {
    bool private roundUp;

    function roundTransfersUp() external {
        roundUp = true;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (roundUp) _burn(from, 1);
    }
}

/// @dev Run loan and repayment transfers and calculate health factor from the resulting balances.
abstract contract PoolFixture {
    uint256 internal constant LIQUIDATION_THRESHOLD = 8_800;
    ERC20Mock internal immutable weth = new ERC20Mock();
    ERC20Mock internal immutable usdc = new ERC20Mock();
    RoundedAToken internal immutable aWeth = new RoundedAToken();
    ERC20Mock internal immutable debt = new ERC20Mock();
    uint128 public FLASHLOAN_PREMIUM_TOTAL;

    function getUserAccountData(address owner) public view returns (uint256[6] memory data) {
        uint256 outstanding = debt.balanceOf(owner);
        uint256 weightedPrice = PercentageMath.percentMulCeil(2_000e6, LIQUIDATION_THRESHOLD);
        data[5] = outstanding == 0 ? type(uint256).max : aWeth.balanceOf(owner) * weightedPrice / outstanding;
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata data, uint16) external {
        uint256 premium = PercentageMath.percentMulCeil(amount, FLASHLOAN_PREMIUM_TOTAL);
        require(asset == address(weth) && weth.transfer(receiver, amount), "loan transfer");
        require(
            AaveV3PositionProtector(receiver).executeOperation(asset, amount, premium, msg.sender, data), "callback"
        );
        require(weth.transferFrom(receiver, address(this), amount + premium), "loan repayment");
    }

    function repay(address asset, uint256 amount, uint256 rateMode, address owner) external returns (uint256) {
        require(asset == address(usdc) && rateMode == uint256(DataTypes.InterestRateMode.VARIABLE), "wrong loan");
        require(usdc.transferFrom(msg.sender, address(this), amount), "debt repayment");
        debt.burn(owner, amount);
        return amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(weth), "wrong collateral");
        aWeth.burn(msg.sender, amount);
        require(weth.transfer(to, amount), "collateral withdrawal");
        return amount;
    }
}

contract AaveV3PositionProtectorTest is CoWProtocol, PoolFixture {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    uint256 private constant PRINCIPAL = 0.025 ether;
    uint128 private constant PREMIUM_BPS = 5;
    uint256 private constant COLLATERAL = 0.0625 ether;
    uint256 private constant CAP = 0.0275 ether;
    uint256 private constant DEBT = 100e6;
    uint256 private constant PROCEEDS = 50e6;
    uint256 private constant TRIGGER = 1.1e18;
    uint256 private constant TARGET = 1.2e18;
    string private constant APP_DATA_SUFFIX = '}},"version":"1.15.0"}';

    struct Trade {
        GPv2Order.Data order;
        bytes signature;
    }

    address private immutable borrower = makeAddr("borrower");
    bytes32 private ruleId;
    ComposableCoW private registry;
    FlashLoanRouter private router;
    AaveV3PositionProtector private protector;
    AavePositionProtectionHandler private immutable handler = new AavePositionProtectionHandler();
    uint32 private expiry;

    function setUp() public override {
        super.setUp();
        router = new FlashLoanRouter(ICowSettlement(address(settlement)));
        registry = new ComposableCoW(address(settlement));
        protector = new AaveV3PositionProtector(handler, registry, IPool(address(this)), router);
        GPv2AllowListAuthentication auth = GPv2AllowListAuthentication(address(settlement.authenticator()));
        vm.prank(admin.addr);
        auth.addSolver(address(router));

        weth.mint(address(this), 1 ether);
        usdc.mint(address(settlement), 1_000e6);
        _open(borrower);
        _mockMarket();
        ruleId = _register(borrower, TARGET, CAP);
    }

    function test_quoteInputs_WaitForQuoteAndUsableReserves() external {
        vm.expectRevert(abi.encodeWithSelector(IConditionalOrder.PollTryNextBlock.selector, "repayment quote required"));
        _quote(ruleId, 0);
        _assertUnavailable(true, false, false, true);
        _assertUnavailable(true, true, false, false);
        _assertUnavailable(true, true, true, true);
        _mockReserve(true, true, false, true);
        _assertUnavailable(false, false, false, false);
        _assertUnavailable(false, true, true, false);
        _mockReserve(false, true, false, false);

        _mockPool(IPool.getReserveNormalizedIncome.selector, 1.5e27);
        IAavePositionProtector.QuoteInputs memory ready = protector.quoteInputs(ruleId);
        assertEq(ready.flashLender, address(this));
        assertEq(ready.collateralDebitBuffer, 2);
    }

    function test_fill_RepaysAtTriggerAndUsesRuleOnce() external {
        Trade memory trade = _quote(ruleId, PROCEEDS);
        IAavePositionProtector.QuoteInputs memory quote = protector.quoteInputs(ruleId);
        assertEq(quote.healthFactor, TRIGGER);
        assertEq(quote.liquidationThreshold, LIQUIDATION_THRESHOLD);
        string memory prefix = '{"metadata":{"utm":{"utmContent":"aave-rule-';
        assertEq(trade.order.appData, keccak256(abi.encodePacked(prefix, vm.toString(ruleId), '"', APP_DATA_SUFFIX)));

        _fill(trade, PROCEEDS);
        assertEq(settlement.filledAmount(_uid(trade.order)), PRINCIPAL);
        assertEq(debt.balanceOf(borrower), DEBT - PROCEEDS);
        assertEq(aWeth.balanceOf(borrower), COLLATERAL - PRINCIPAL);
        assertEq(aWeth.allowance(borrower, address(protector)), type(uint256).max);
        assertGe(getUserAccountData(borrower)[5], TARGET);
        assertEq(protector.quoteInputs(ruleId).borrower, address(0));
        assertEq(weth.allowance(address(protector), address(this)), 0);
        assertEq(usdc.allowance(address(protector), address(this)), 0);
        assertEq(weth.allowance(address(protector), relayer), 0);
        vm.expectRevert(IAavePositionProtector.InvalidRule.selector);
        _fill(trade, PROCEEDS);
    }

    function test_fill_RepaysOnlyTheBorrowerSelectedByTheOrder() external {
        address second = makeAddr("second borrower");
        _open(second);
        Trade memory firstTrade = _quote(ruleId, PROCEEDS);
        Trade memory secondTrade = _quote(_register(second, TARGET, CAP), PROCEEDS);
        _fill(secondTrade, PROCEEDS);
        assertEq(debt.balanceOf(borrower), DEBT);
        _fill(firstTrade, PROCEEDS);
        assertEq(debt.balanceOf(borrower), DEBT - PROCEEDS);
        assertEq(debt.balanceOf(second), DEBT - PROCEEDS);
    }

    function test_fill_ChargesPremiumAndRefundsSurplusWithoutSpendingExistingBalances() external {
        FLASHLOAN_PREMIUM_TOTAL = PREMIUM_BPS;
        weth.mint(address(protector), 1 ether);
        usdc.mint(address(protector), 3e6);
        aWeth.mint(address(protector), 2 ether);

        assertEq(protector.quoteInputs(ruleId).premiumBps, PREMIUM_BPS);
        _fill(_quote(ruleId, PROCEEDS), DEBT + 5e6);
        assertEq(aWeth.balanceOf(borrower), COLLATERAL - PRINCIPAL - 0.0000125 ether);
        assertEq(debt.balanceOf(borrower), 0);
        assertEq(usdc.balanceOf(borrower), 5e6);
        assertEq(weth.balanceOf(address(protector)), 1 ether);
        assertEq(usdc.balanceOf(address(protector)), 3e6);
        assertEq(aWeth.balanceOf(address(protector)), 2 ether);
    }

    function test_fill_RoundsPremiumAwarePriceFloorUp() external {
        FLASHLOAN_PREMIUM_TOTAL = PREMIUM_BPS;
        aWeth.roundTransfersUp();
        uint256 floor = 48_524_251;
        Trade memory trade = _quote(ruleId, floor - 1);
        _assertFailedFill(
            trade,
            floor - 1,
            abi.encodeWithSelector(IAavePositionProtector.PriceBelowOracleFloor.selector, floor - 1, floor)
        );
        _fill(trade, floor);
    }

    function test_fill_RevertsWithoutFlashLoanContext() external {
        Trade memory trade = _quote(ruleId, PROCEEDS);
        bytes memory data = _settlementCall(trade, PROCEEDS);
        vm.prank(solver.addr);
        (bool ok, bytes memory reason) = address(settlement).call(data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IAavePositionProtector.InvalidLoan.selector));
        _assertRolledBack(trade);
    }

    function test_cancel_InvalidatesSavedOrder() external {
        Trade memory trade = _quote(ruleId, PROCEEDS);
        vm.prank(borrower);
        protector.cancel(ruleId);
        _assertRearm();
        vm.expectRevert(IAavePositionProtector.InvalidRule.selector);
        _fill(trade, PROCEEDS);
    }

    function test_expiry_SkipsMarketReadsAndInvalidatesSavedOrder() external {
        Trade memory trade = _quote(ruleId, PROCEEDS);
        vm.warp(expiry);
        vm.mockCall(address(this), abi.encodeCall(IPool.getReserveData, (address(weth))), "");
        assertEq(protector.quoteInputs(ruleId).config.expiry, expiry);
        vm.expectRevert(IAavePositionProtector.InvalidRule.selector);
        _fill(trade, PROCEEDS);
        _mockReserve(true, true, false, true);
        _assertRearm();
    }

    function test_fill_RevertsRevokedAllowance() external {
        Trade memory trade = _quote(ruleId, PROCEEDS);
        vm.prank(borrower);
        aWeth.approve(address(protector), 0);
        vm.expectRevert(IAavePositionProtector.InsufficientCollateralAllowance.selector);
        _fill(trade, PROCEEDS);
    }

    function test_fill_RollsBackActualCollateralAboveCap() external {
        _replace(TARGET, PRINCIPAL);
        aWeth.roundTransfersUp();
        Trade memory trade = _quote(ruleId, PROCEEDS);
        _assertFailedFill(
            trade, PROCEEDS, abi.encodeWithSelector(IAavePositionProtector.CollateralCapExceeded.selector)
        );
    }

    function testFuzz_fill_RollsBackWhenResultInvalid(bool shortReceipt) external {
        bytes memory reason;
        if (shortReceipt) {
            vm.mockCall(address(this), abi.encodeWithSelector(IPool.withdraw.selector), abi.encode(0));
            reason = abi.encodeWithSelector(IAavePositionProtector.UnexpectedTokenMovement.selector);
        } else {
            _replace(1.4e18, CAP);
            reason = abi.encodeWithSelector(IAavePositionProtector.TargetHealthFactorMissed.selector, 1.32e18);
        }
        _assertFailedFill(_quote(ruleId, PROCEEDS), PROCEEDS, reason);
    }

    function _open(address owner) private {
        aWeth.mint(owner, COLLATERAL);
        debt.mint(owner, DEBT);
        vm.prank(owner);
        aWeth.approve(address(protector), type(uint256).max);
    }

    function _mockMarket() private {
        _mockReserve(true, true, false, true);
        _mockReserve(false, true, false, false);
        _mockPool(IPool.ADDRESSES_PROVIDER.selector, uint160(address(this)));
        _mockPool(IPoolAddressesProvider.getPriceOracle.selector, uint160(address(this)));
        vm.mockCall(address(this), abi.encodeCall(IPool.getReserveAToken, (address(weth))), abi.encode(aWeth));
        vm.mockCall(address(this), abi.encodeCall(IPool.getReserveVariableDebtToken, (address(usdc))), abi.encode(debt));
        // WETH (reserve 0) is collateral. USDC (reserve 1) is borrowed.
        _mockPool(IPool.getUserConfiguration.selector, 6);
        _mockPool(IPool.getUserEMode.selector, 0);
        _mockPool(IPool.getReserveNormalizedIncome.selector, 1e27);
        vm.mockCall(
            address(this), abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(weth))), abi.encode(2_000e8)
        );
        vm.mockCall(address(this), abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(usdc))), abi.encode(1e8));
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
    }

    function _mockReserve(bool collateral, bool active, bool paused, bool flashEnabled) private {
        DataTypes.ReserveDataLegacy memory reserve;
        reserve.configuration.setActive(active);
        reserve.configuration.setPaused(paused);
        reserve.configuration.setFlashLoanEnabled(flashEnabled);
        reserve.configuration.setLiquidationThreshold(collateral ? LIQUIDATION_THRESHOLD : 0);
        reserve.id = collateral ? 0 : 1;
        reserve.aTokenAddress = collateral ? address(aWeth) : address(0);
        reserve.variableDebtTokenAddress = collateral ? address(0) : address(debt);
        address asset = address(collateral ? weth : usdc);
        vm.mockCall(address(this), abi.encodeCall(IPool.getReserveData, (asset)), abi.encode(reserve));
    }

    function _mockPool(bytes4 selector, uint256 result) private {
        vm.mockCall(address(this), abi.encodeWithSelector(selector), abi.encode(result));
    }

    function _assertUnavailable(bool collateral, bool active, bool paused, bool flashEnabled) private {
        _mockReserve(collateral, active, paused, flashEnabled);
        assertEq(protector.quoteInputs(ruleId).flashLender, address(0));
    }

    function _register(address owner, uint256 target, uint256 cap) private returns (bytes32) {
        expiry = uint32(block.timestamp + 1 hours);
        IAavePositionProtector.RuleConfig memory config =
            IAavePositionProtector.RuleConfig(weth, usdc, TRIGGER, target, cap, expiry, 300);
        vm.prank(owner);
        return protector.registerProtection(config);
    }

    function _replace(uint256 target, uint256 cap) private {
        vm.prank(borrower);
        protector.cancel(ruleId);
        ruleId = _register(borrower, target, cap);
    }

    function _assertRearm() private {
        bytes32 next = _register(borrower, TARGET, CAP);
        vm.expectRevert(ComposableCoW.SingleOrderNotAuthed.selector);
        _quote(ruleId, PROCEEDS);
        _quote(next, PROCEEDS);
    }

    function _quote(bytes32 id, uint256 proceeds) private view returns (Trade memory trade) {
        bytes memory data;
        if (proceeds != 0) {
            data = abi.encode(AavePositionProtectionHandler.Quote(PRINCIPAL, proceeds, APP_DATA_SUFFIX, expiry));
        }
        IConditionalOrder.ConditionalOrderParams memory params =
            IConditionalOrder.ConditionalOrderParams(handler, bytes32(0), abi.encode(id));
        (trade.order, trade.signature) =
            registry.getTradeableOrderWithSignature(address(protector), params, data, new bytes32[](0));
    }

    function _fill(Trade memory trade, uint256 proceeds) private {
        bytes memory data = _settlementCall(trade, proceeds);
        Loan.Data[] memory loans = new Loan.Data[](1);
        loans[0] = Loan.Data(PRINCIPAL, IBorrower(address(protector)), address(this), RouterToken(address(weth)));
        vm.prank(solver.addr);
        router.flashLoanAndSettle(loans, data);
    }

    function _settlementCall(Trade memory trade, uint256 proceeds) private view returns (bytes memory) {
        GPv2Order.Data memory order = trade.order;
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = order.sellToken;
        tokens[1] = order.buyToken;
        uint256[] memory prices = new uint256[](2);
        prices[0] = proceeds;
        prices[1] = order.sellAmount;
        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: order.receiver,
            sellAmount: order.sellAmount,
            buyAmount: order.buyAmount,
            validTo: order.validTo,
            appData: order.appData,
            feeAmount: order.feeAmount,
            flags: GPv2TradeEncoder.encodeFlags(order, GPv2Signing.Scheme.Eip1271),
            executedAmount: order.sellAmount,
            signature: abi.encodePacked(address(protector), trade.signature)
        });
        GPv2Interaction.Data[][3] memory interactions;
        return abi.encodeCall(GPv2Settlement.settle, (tokens, prices, trades, interactions));
    }

    function _uid(GPv2Order.Data memory order) private view returns (bytes memory uid) {
        uid = abi.encodePacked(GPv2Order.hash(order, settlement.domainSeparator()), address(protector), order.validTo);
    }

    function _assertRolledBack(Trade memory trade) private {
        assertEq(settlement.filledAmount(_uid(trade.order)), 0);
        assertEq(debt.balanceOf(borrower), DEBT);
        assertEq(aWeth.balanceOf(borrower), COLLATERAL);
        assertEq(protector.quoteInputs(ruleId).borrower, borrower);
    }

    function _assertFailedFill(Trade memory trade, uint256 proceeds, bytes memory reason) private {
        vm.expectRevert(reason);
        _fill(trade, proceeds);
        _assertRolledBack(trade);
    }
}
