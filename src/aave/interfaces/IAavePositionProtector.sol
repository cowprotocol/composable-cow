// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Shared Aave protection executor
/// @notice Lets a borrower authorize one future CoW sale to repay their Aave debt.
/// @dev The executor owns and receives the CoW order. The borrower owns the position and grants collateral permission.
interface IAavePositionProtector {
    /// @notice Terms authorized by the borrower at registration.
    /// @dev Both health factors use 18 decimals. The cap is in collateral base units and includes the Aave premium.
    struct RuleConfig {
        IERC20 collateralToken;
        IERC20 debtToken;
        uint256 triggerHF;
        uint256 targetHF;
        uint256 cap;
        uint32 expiry; // Zero keeps the rule active until cancellation or use.
        uint16 maxPriceDiscountBps;
    }

    /// @notice Aave position and market data needed to size a quote at one block.
    /// @dev A zero flash lender indicates an ineligible rule. V4 debt includes the position's risk premium.
    ///      The threshold is in BPS and uses the factor that will apply after withdrawal.
    ///      The debit buffer bounds share rounding at the quote block, in collateral base units.
    struct QuoteInputs {
        address borrower;
        RuleConfig config;
        uint256 healthFactor;
        uint256 allowance;
        address flashLender;
        uint256 collateralBalance;
        uint256 debtAmount;
        uint256 liquidationThreshold;
        uint128 premiumBps;
        uint256 collateralPrice;
        uint256 debtPrice;
        uint8 collateralDecimals;
        uint8 debtDecimals;
        uint256 collateralDebitBuffer;
    }

    /// @notice The registry and router must use the same settlement domain, with a configured vault relayer.
    error InvalidDeployment();
    /// @notice Only the rule's borrower can cancel it.
    error BorrowerOnly();
    /// @notice The rule, its terms, or the requested order lifetime is invalid.
    error InvalidRule();
    /// @notice The account must use the rule's supported collateral and debt reserves.
    error UnsupportedPosition();
    /// @notice The account is outside the interval between liquidation and the configured trigger.
    error IneligibleHealthFactor(uint256 healthFactor);
    /// @notice The borrower's collateral allowance must cover the configured cap.
    error InsufficientCollateralAllowance();
    /// @notice The router request, Aave callback, or settlement trade does not match the active loan.
    error InvalidLoan();
    /// @notice The principal, principal plus premium, or measured collateral debit exceeds the cap.
    error CollateralCapExceeded();
    /// @notice The Aave oracle returned a zero price for one of the two reserves.
    error InvalidOraclePrice();
    /// @notice The proceeds are below the rule's discounted oracle value for the measured collateral debit.
    error PriceBelowOracleFloor(uint256 proceeds, uint256 minimum);
    /// @notice The borrower's final health factor is below the target.
    error TargetHealthFactorMissed(uint256 healthFactor);
    /// @notice The borrower did not repay any of the intended variable debt.
    error DebtNotReduced();
    /// @notice The settlement or repayment moved an unexpected balance or left an allowance.
    error UnexpectedTokenMovement();
    /// @notice A CoW fill reduced the borrower's debt and satisfied the rule.
    /// @dev The same receipt contains the CoW Trade and Aave Repay and FlashLoan events.
    /// @param ruleId ID of the rule that was consumed.
    /// @param collateralSpent Measured position debit, in collateral base units.
    /// @param finalHF Health factor after Aave collected the loan repayment, scaled by 1e18.

    event ProtectionUsed(bytes32 indexed ruleId, uint256 collateralSpent, uint256 finalHF);

    /// @notice Registers a single ComposableCoW order for the caller.
    /// @dev The caller must already have a supported position and grant the market's collateral permission.
    ///      Cancel an active rule or wait for its configured expiry, if any, before registering another.
    /// @param config The position's two assets, execution thresholds, cap, deadline, and price discount.
    /// @return id The borrower's address followed by their next rule version, registered as static input.
    function registerProtection(RuleConfig calldata config) external returns (bytes32 id);

    /// @notice Cancels the borrower's registered rule and removes its order from ComposableCoW.
    /// @param ruleId ID of the rule to cancel.
    function cancel(bytes32 ruleId) external;

    /// @notice Reads the rule and the Aave inputs for an eligible quote.
    /// @param ruleId Rule to look up.
    /// @return inputs Status and market data. A zero flash lender means the rule is ineligible.
    function quoteInputs(bytes32 ruleId) external view returns (QuoteInputs memory inputs);

    /// @notice Makes the flash loan principal and actual premium available for Aave to collect.
    /// @param asset The borrowed reserve asset.
    /// @param amount The principal sent by the pool.
    /// @param premium The premium charged by the pool, which may be zero.
    /// @param initiator The account that requested the loan.
    /// @param data The callback data supplied when the loan was requested.
    /// @return accepted True when the pool can collect the repayment.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata data)
        external
        returns (bool accepted);

    /// @notice Borrows collateral from Aave and calls the configured router to settle the chosen protection order.
    /// @dev Reads the rule from the ComposableCoW signature in the forwarded settlement.
    /// @param lender The pool the router requested. It must match the configured Aave pool.
    /// @param token Collateral token to borrow.
    /// @param amount Flash loan principal, which must match the full fill's sell amount.
    /// @param callbackData The router's settlement payload, forwarded unchanged.
    function flashLoanAndCallBack(address lender, address token, uint256 amount, bytes calldata callbackData)
        external;

    /// @notice Checks whether a quote can be signed or executed for the specified rule.
    /// @dev CoW settlement also requires this rule and sell amount to match the running flash loan.
    /// @param ruleId Rule ID committed by the ComposableCoW registration.
    /// @param sellAmount Full-fill collateral sale amount and flash loan principal.
    /// @param validTo Order expiry, which must be no later than the rule expiry when one is set.
    /// @param sender Caller forwarded by ComposableCoW.
    /// @return sellToken Collateral token that the order sells.
    /// @return buyToken Debt token that the order buys.
    function validateOrder(bytes32 ruleId, uint256 sellAmount, uint32 validTo, address sender)
        external
        view
        returns (address sellToken, address buyToken);
}
