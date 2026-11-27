// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {ReserveConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";
import {GPv2Settlement} from "cowprotocol/contracts/GPv2Settlement.sol";

import {IFlashLoanRouter} from "../../lib/flash-loan-router/src/interface/IFlashLoanRouter.sol";
import {ComposableCoW} from "../ComposableCoW.sol";
import {ERC1271Forwarder} from "../ERC1271Forwarder.sol";
import {IConditionalOrder} from "../interfaces/IConditionalOrder.sol";
import {ConditionalOrdersUtilsLib} from "../types/ConditionalOrdersUtilsLib.sol";
import {AaveProtectionSettlement} from "./AaveProtectionSettlement.sol";
import {IAavePositionProtector} from "./interfaces/IAavePositionProtector.sol";

/// @notice Shares Aave protection rule and settlement logic across markets.
abstract contract BaseAavePositionProtector is ERC1271Forwarder, IAavePositionProtector {
    using SafeERC20 for IERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    struct Rule {
        // Clearing the config preserves the version so an old order cannot be reactivated.
        uint96 version;
        RuleConfig config;
    }

    enum LoanPhase {
        Idle,
        Borrowing, // Awaiting the Aave callback.
        Settling, // CoW can verify the active order.
        Repaying // CoW has returned and Aave can collect repayment.

    }

    struct Loan {
        bytes32 ruleId;
        uint256 amount; // Principal during settlement, measured collateral debit after settlement.
        LoanPhase phase;
    }

    struct Position {
        uint256 debt;
        uint256 liquidationThreshold;
        uint256 allowance;
        uint256 healthFactor;
        uint256 collateralBalance;
        uint256 collateralDebitBuffer;
    }

    uint256 private constant LIQUIDATION_HEALTH_FACTOR = 1e18;

    // ERC-7201 root for the three consecutive transient slots, in Loan field order.
    // cast index-erc7201 composable-cow.aave-protection.loan
    uint256 private constant LOAN_RULE_SLOT = 0xf50644ecfb868e820df21e00da54e3e7ea7d9c344c5f4fa9b1fcc545ac2b0200;

    IPool internal immutable pool;
    IFlashLoanRouter private immutable router;

    IConditionalOrder private immutable handler;
    GPv2Settlement private immutable settlement;
    address private immutable vaultRelayer;
    address private immutable debtRepayer;

    mapping(address borrower => Rule) private rules;

    /// @param handler_ Conditional order generator shared by every borrower.
    /// @param registry ComposableCoW registry configured for the router's CoW settlement domain.
    /// @param pool_ Trusted Aave V3 pool that funds flash loans.
    /// @param router_ CoW flash loan router allowed to start a fill.
    /// @param debtRepayer_ Address approved to spend the debt token for repayment.
    constructor(
        IConditionalOrder handler_,
        ComposableCoW registry,
        IPool pool_,
        IFlashLoanRouter router_,
        address debtRepayer_
    ) ERC1271Forwarder(registry) {
        if (address(handler_).code.length == 0 || address(pool_).code.length == 0) revert InvalidDeployment();
        router = router_;
        pool = pool_;
        debtRepayer = debtRepayer_;
        handler = handler_;
        settlement = GPv2Settlement(payable(address(router_.settlementContract())));
        vaultRelayer = address(settlement.vaultRelayer());
        if (vaultRelayer == address(0) || registry.domainSeparator() != settlement.domainSeparator()) {
            revert InvalidDeployment();
        }
    }

    /// @inheritdoc IAavePositionProtector
    function registerProtection(RuleConfig calldata config) external override returns (bytes32 id) {
        if (_readLoan().phase != LoanPhase.Idle) revert InvalidRule();
        if (config.triggerHF <= LIQUIDATION_HEALTH_FACTOR || config.targetHF <= config.triggerHF) revert InvalidRule();
        if (
            config.cap == 0 || _isExpired(config.expiry)
                || config.maxPriceDiscountBps >= ConditionalOrdersUtilsLib.MAX_BPS
        ) revert InvalidRule();

        Rule storage rule = rules[msg.sender];
        if (rule.config.cap != 0) {
            if (!_isExpired(rule.config.expiry)) revert InvalidRule();
            // An expired registration still exists in ComposableCoW until removed.
            bytes32 expiredId = bytes32(abi.encodePacked(msg.sender, rule.version));
            composableCoW.remove(composableCoW.hash(_orderParams(expiredId)));
        }

        // The address locates the borrower. The version distinguishes replacement rules.
        id = bytes32(abi.encodePacked(msg.sender, ++rule.version));
        rule.config = config;
        _requirePositionAndAllowance(msg.sender, rule.config);
        composableCoW.create(_orderParams(id), true);
    }

    /// @inheritdoc IAavePositionProtector
    function cancel(bytes32 ruleId) external override {
        if (address(bytes20(ruleId)) != msg.sender) revert BorrowerOnly();
        if (_readLoan().phase != LoanPhase.Idle || !_isCurrentRule(rules[msg.sender], ruleId)) {
            revert InvalidRule();
        }
        _clearRule(msg.sender, ruleId);
    }

    /// @inheritdoc IAavePositionProtector
    function quoteInputs(bytes32 ruleId) external view override returns (QuoteInputs memory inputs) {
        address borrower = address(bytes20(ruleId));
        Rule storage rule = rules[borrower];
        if (!_isCurrentRule(rule, ruleId)) return inputs;

        RuleConfig storage config = rule.config;
        inputs.borrower = borrower;
        inputs.config = config;
        if (_isExpired(config.expiry)) return inputs;

        Position memory position = _position(borrower, config, true);
        inputs.debtAmount = position.debt;
        inputs.liquidationThreshold = position.liquidationThreshold;
        inputs.healthFactor = position.healthFactor;
        inputs.allowance = position.allowance;

        // Leave the lender unset until the position and market pass the quote checks.
        if (position.collateralBalance == 0) return inputs;

        inputs.flashLender = address(pool);
        inputs.collateralBalance = position.collateralBalance;
        inputs.collateralDebitBuffer = position.collateralDebitBuffer;
        (inputs.collateralPrice, inputs.debtPrice, inputs.collateralDecimals, inputs.debtDecimals) =
            _marketPrices(config.collateralToken, config.debtToken);
        inputs.premiumBps = pool.FLASHLOAN_PREMIUM_TOTAL();
    }

    /// @inheritdoc IAavePositionProtector
    function validateOrder(bytes32 ruleId, uint256 sellAmount, uint32 validTo, address sender)
        external
        view
        override
        returns (address sellToken, address buyToken)
    {
        // A preview can run before a loan exists. A fill must match the active loan.
        if (sender == address(settlement)) {
            Loan memory loan = _readLoan();
            if (loan.phase != LoanPhase.Settling || loan.ruleId != ruleId || loan.amount != sellAmount) {
                revert InvalidLoan();
            }
        }

        (address borrower, RuleConfig storage config) = _config(ruleId);
        if (validTo <= block.timestamp || (config.expiry != 0 && validTo > config.expiry)) revert InvalidRule();
        _requireEligible(borrower, config, sellAmount);
        return (address(config.collateralToken), address(config.debtToken));
    }

    /// @inheritdoc IAavePositionProtector
    /// @dev The protected CoW trade identifies the borrower. The rule stays locked until Aave collects repayment.
    function flashLoanAndCallBack(address lender, address token, uint256 amount, bytes calldata callbackData)
        external
        override
    {
        if (msg.sender != address(router) || lender != address(pool) || _readLoan().phase != LoanPhase.Idle) {
            revert InvalidLoan();
        }

        // Find the rule in the forwarded trade. Its signature is checked during settlement.
        bytes32 ruleId = AaveProtectionSettlement.ruleId(callbackData, handler);
        (address borrower, RuleConfig storage config) = _config(ruleId);
        IERC20 collateral = config.collateralToken;
        if (token != address(collateral)) revert InvalidLoan();

        uint256 debtBefore = _requireEligible(borrower, config, amount);
        uint256 collateralBefore = collateral.balanceOf(address(this));

        // Aave calls executeOperation and collects the repayment before this call returns.
        _writeLoan(Loan(ruleId, amount, LoanPhase.Borrowing));
        // V3 Core funds both versions. Unlike full flashLoan, flashLoanSimple applies the configured premium.
        pool.flashLoanSimple(address(this), token, amount, callbackData, 0);

        Loan memory completed = _readLoan();
        if (
            completed.phase != LoanPhase.Repaying || collateral.balanceOf(address(this)) != collateralBefore
                || collateral.allowance(address(this), address(pool)) != 0
                || collateral.allowance(address(this), vaultRelayer) != 0
                || config.debtToken.allowance(address(this), debtRepayer) != 0
        ) revert UnexpectedTokenMovement();

        // Check the borrower's position after Aave has collected the loan repayment.
        uint256 debtAfter = _debtBalance(borrower, config);
        uint256 finalHF = _healthFactor(borrower);
        if (debtAfter >= debtBefore) revert DebtNotReduced();
        if (finalHF < config.targetHF) revert TargetHealthFactorMissed(finalHF);

        _clearRule(borrower, ruleId);
        emit ProtectionUsed(ruleId, completed.amount, finalHF);

        // The router can settle another borrower's order in the same transaction.
        _writeLoan(Loan(bytes32(0), 0, LoanPhase.Idle));
    }

    /// @inheritdoc IAavePositionProtector
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata data)
        external
        override
        returns (bool accepted)
    {
        if (msg.sender != address(pool) || initiator != address(this)) revert InvalidLoan();
        Loan memory loan = _readLoan();
        if (loan.phase != LoanPhase.Borrowing || loan.amount != amount) revert InvalidLoan();

        address borrower = address(bytes20(loan.ruleId));
        RuleConfig storage config = rules[borrower].config;
        if (asset != address(config.collateralToken)) revert InvalidLoan();
        if (premium > config.cap - amount) revert CollateralCapExceeded();

        // Take the oracle snapshot before CoW runs any solver interactions.
        (uint256 priceNumerator, uint256 priceDenominator) = _oraclePriceFloor(config);
        uint256 proceeds = _settleAndRepay(borrower, config, loan, data);

        // Repaying debt first lets Aave check the collateral withdrawal against the reduced debt.
        uint256 repayment = amount + premium;
        uint256 collateralSpent = _withdrawCollateral(borrower, config, repayment);

        // Use the actual collateral debit, including the premium and reserve rounding.
        uint256 minimumProceeds = Math.mulDiv(collateralSpent, priceNumerator, priceDenominator, Math.Rounding.Up);
        if (proceeds < minimumProceeds) revert PriceBelowOracleFloor(proceeds, minimumProceeds);

        // CoW has finished checking the principal. Reuse its slot for the debit in ProtectionUsed.
        loan.amount = collateralSpent;
        _writeLoan(loan);
        config.collateralToken.forceApprove(address(pool), repayment);
        return true;
    }

    // Settlement accounting

    function _settleAndRepay(address borrower, RuleConfig storage config, Loan memory loan, bytes calldata data)
        private
        returns (uint256 proceeds)
    {
        IERC20 debt = config.debtToken;
        uint256 debtBalanceBefore = debt.balanceOf(address(this));

        {
            IERC20 collateral = config.collateralToken;
            uint256 collateralWithLoan = collateral.balanceOf(address(this));

            // CoW may verify this order and pull exactly the principal during settlement.
            loan.phase = LoanPhase.Settling;
            _writeLoan(loan);
            collateral.forceApprove(vaultRelayer, loan.amount);
            router.borrowerCallBack(data);
            // Close the signature check window as soon as settlement returns.
            loan.phase = LoanPhase.Repaying;
            _writeLoan(loan);

            if (collateral.balanceOf(address(this)) != collateralWithLoan - loan.amount) {
                revert UnexpectedTokenMovement();
            }
        }

        uint256 debtBalanceAfter = debt.balanceOf(address(this));
        if (debtBalanceAfter <= debtBalanceBefore) revert DebtNotReduced();

        // Only this fill's proceeds are available to repay this borrower.
        proceeds = debtBalanceAfter - debtBalanceBefore;
        uint256 repayment = Math.min(proceeds, _debtBalance(borrower, config));
        if (repayment == 0) revert DebtNotReduced();

        debt.forceApprove(debtRepayer, repayment);
        _repayDebt(borrower, config, repayment);
        if (debt.allowance(address(this), debtRepayer) != 0) debt.forceApprove(debtRepayer, 0);

        // Return only this fill's excess so unrelated funds stay in the executor.
        uint256 surplus = debt.balanceOf(address(this)) - debtBalanceBefore;
        if (surplus != 0) debt.safeTransfer(borrower, surplus);
    }

    function _oraclePriceFloor(RuleConfig storage config)
        private
        view
        returns (uint256 numerator, uint256 denominator)
    {
        (uint256 collateralPrice, uint256 debtPrice, uint8 collateralDecimals, uint8 debtDecimals) =
            _marketPrices(config.collateralToken, config.debtToken);
        uint256 bps = ConditionalOrdersUtilsLib.MAX_BPS;
        // Express the floor as debt base units per collateral base unit.
        numerator = collateralPrice * (bps - config.maxPriceDiscountBps) * 10 ** uint256(debtDecimals);
        denominator = debtPrice * 10 ** uint256(collateralDecimals) * bps;
    }

    // Rule checks and registration

    function _canQuote(Position memory position, RuleConfig storage config) internal view returns (bool) {
        return position.debt != 0 && position.allowance >= config.cap
            && position.healthFactor > LIQUIDATION_HEALTH_FACTOR && position.healthFactor <= config.triggerHF;
    }

    function _flashLoanAvailable(DataTypes.ReserveConfigurationMap memory reserve) internal pure returns (bool) {
        return reserve.getActive() && !reserve.getPaused() && reserve.getFlashLoanEnabled();
    }

    function _requireEligible(address borrower, RuleConfig storage config, uint256 amount)
        private
        view
        returns (uint256 debt)
    {
        if (_isExpired(config.expiry) || amount == 0) revert InvalidRule();
        if (amount > config.cap) revert CollateralCapExceeded();
        Position memory position = _requirePositionAndAllowance(borrower, config);
        debt = position.debt;
        uint256 hf = position.healthFactor;
        if (hf <= LIQUIDATION_HEALTH_FACTOR || hf > config.triggerHF) revert IneligibleHealthFactor(hf);
    }

    function _requirePositionAndAllowance(address borrower, RuleConfig storage config)
        private
        view
        returns (Position memory position)
    {
        position = _position(borrower, config, false);
        if (position.debt == 0) revert UnsupportedPosition();
        if (position.allowance < config.cap) revert InsufficientCollateralAllowance();
    }

    function _config(bytes32 id) private view returns (address borrower, RuleConfig storage config) {
        borrower = address(bytes20(id));
        Rule storage rule = rules[borrower];
        if (!_isCurrentRule(rule, id)) revert InvalidRule();
        return (borrower, rule.config);
    }

    function _isCurrentRule(Rule storage rule, bytes32 id) private view returns (bool) {
        return rule.config.cap != 0 && rule.version == uint96(uint256(id));
    }

    function _isExpired(uint32 expiry) private view returns (bool) {
        return expiry != 0 && expiry <= block.timestamp;
    }

    function _orderParams(bytes32 id) private view returns (IConditionalOrder.ConditionalOrderParams memory) {
        return IConditionalOrder.ConditionalOrderParams(handler, bytes32(0), abi.encode(id));
    }

    function _clearRule(address borrower, bytes32 id) private {
        delete rules[borrower].config;
        composableCoW.remove(composableCoW.hash(_orderParams(id)));
    }

    function _readLoan() private view returns (Loan memory loan) {
        assembly ("memory-safe") {
            mstore(loan, tload(LOAN_RULE_SLOT))
            mstore(add(loan, 0x20), tload(add(LOAN_RULE_SLOT, 1)))
            mstore(add(loan, 0x40), tload(add(LOAN_RULE_SLOT, 2)))
        }
    }

    function _writeLoan(Loan memory loan) private {
        assembly ("memory-safe") {
            tstore(LOAN_RULE_SLOT, mload(loan))
            tstore(add(LOAN_RULE_SLOT, 1), mload(add(loan, 0x20)))
            tstore(add(LOAN_RULE_SLOT, 2), mload(add(loan, 0x40)))
        }
    }

    function _withdrawCollateral(address borrower, RuleConfig storage config, uint256 repayment)
        internal
        virtual
        returns (uint256 spent);

    function _marketPrices(IERC20 collateral, IERC20 debt)
        internal
        view
        virtual
        returns (uint256 collateralPrice, uint256 debtPrice, uint8 collateralDecimals, uint8 debtDecimals);

    function _position(address borrower, RuleConfig storage config, bool forQuote)
        internal
        view
        virtual
        returns (Position memory position);

    function _repayDebt(address borrower, RuleConfig storage config, uint256 repayment) internal virtual;

    function _debtBalance(address borrower, RuleConfig storage config) internal view virtual returns (uint256);

    function _healthFactor(address borrower) internal view virtual returns (uint256 hf);
}
