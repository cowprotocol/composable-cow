// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol";
import {ReserveConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {UserConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import {WadRayMath} from "aave-v3-origin/contracts/protocol/libraries/math/WadRayMath.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";

import {IFlashLoanRouter} from "../../lib/flash-loan-router/src/interface/IFlashLoanRouter.sol";
import {ComposableCoW} from "../ComposableCoW.sol";
import {IConditionalOrder} from "../interfaces/IConditionalOrder.sol";
import {BaseAavePositionProtector} from "./BaseAavePositionProtector.sol";

/// @notice Protects positions in an Aave V3 Origin Pool.
/// @dev Supports one enabled collateral reserve, one variable-debt reserve and e-mode off.
contract AaveV3PositionProtector is BaseAavePositionProtector {
    using SafeERC20 for IERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using UserConfiguration for DataTypes.UserConfigurationMap;

    constructor(IConditionalOrder handler_, ComposableCoW registry, IPool pool_, IFlashLoanRouter router_)
        BaseAavePositionProtector(handler_, registry, pool_, router_, address(pool_))
    {}

    function _withdrawCollateral(address borrower, RuleConfig storage config, uint256 repayment)
        internal
        override
        returns (uint256 spent)
    {
        address collateral = address(config.collateralToken);
        IERC20 aToken = IERC20(pool.getReserveAToken(collateral));
        uint256 collateralBefore = aToken.balanceOf(borrower);
        uint256 executorCollateralBefore = aToken.balanceOf(address(this));

        aToken.safeTransferFrom(borrower, address(this), repayment);
        uint256 received = pool.withdraw(collateral, repayment, address(this));
        spent = collateralBefore - aToken.balanceOf(borrower);
        if (spent > config.cap) revert CollateralCapExceeded();
        if (received != repayment || aToken.balanceOf(address(this)) < executorCollateralBefore) {
            revert UnexpectedTokenMovement();
        }
    }

    function _marketPrices(IERC20 collateral, IERC20 debt)
        internal
        view
        override
        returns (uint256 collateralPrice, uint256 debtPrice, uint8 collateralDecimals, uint8 debtDecimals)
    {
        IPriceOracleGetter oracle = IPriceOracleGetter(pool.ADDRESSES_PROVIDER().getPriceOracle());
        collateralPrice = oracle.getAssetPrice(address(collateral));
        debtPrice = oracle.getAssetPrice(address(debt));
        if (collateralPrice == 0 || debtPrice == 0) revert InvalidOraclePrice();
        collateralDecimals = IERC20Metadata(address(collateral)).decimals();
        debtDecimals = IERC20Metadata(address(debt)).decimals();
    }

    function _position(address borrower, RuleConfig storage config, bool forQuote)
        internal
        view
        override
        returns (Position memory position)
    {
        DataTypes.ReserveDataLegacy memory collateral = pool.getReserveData(address(config.collateralToken));
        DataTypes.ReserveDataLegacy memory borrowed = pool.getReserveData(address(config.debtToken));
        IERC20 aToken = IERC20(collateral.aTokenAddress);
        position.healthFactor = _healthFactor(borrower);
        if (address(aToken) != address(0)) position.allowance = aToken.allowance(borrower, address(this));
        if (
            address(aToken) == address(0) || borrowed.variableDebtTokenAddress == address(0)
                || collateral.id == borrowed.id || pool.getUserEMode(borrower) != 0
        ) return position;

        DataTypes.UserConfigurationMap memory user = pool.getUserConfiguration(borrower);
        if (
            !user.isUsingAsCollateralOne() || !user.isUsingAsCollateral(collateral.id) || !user.isBorrowingOne()
                || !user.isBorrowing(borrowed.id)
        ) return position;

        position.debt = IERC20(borrowed.variableDebtTokenAddress).balanceOf(borrower);
        position.liquidationThreshold = collateral.configuration.getLiquidationThreshold();
        // Quotes need the balance and a buffer for rounding shares up and assets down.
        if (
            forQuote && _canQuote(position, config) && _flashLoanAvailable(collateral.configuration)
                && borrowed.configuration.getActive() && !borrowed.configuration.getPaused()
        ) {
            position.collateralBalance = aToken.balanceOf(borrower);
            position.collateralDebitBuffer =
                Math.ceilDiv(pool.getReserveNormalizedIncome(address(config.collateralToken)), WadRayMath.RAY);
        }
    }

    function _repayDebt(address borrower, RuleConfig storage config, uint256 repayment) internal override {
        pool.repay(address(config.debtToken), repayment, uint256(DataTypes.InterestRateMode.VARIABLE), borrower);
    }

    function _debtBalance(address borrower, RuleConfig storage config) internal view override returns (uint256) {
        return IERC20(pool.getReserveVariableDebtToken(address(config.debtToken))).balanceOf(borrower);
    }

    function _healthFactor(address borrower) internal view override returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(borrower);
    }
}
