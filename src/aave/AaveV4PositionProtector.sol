// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IHub} from "aave-v4/src/hub/interfaces/IHub.sol";
import {IGiverPositionManager} from "aave-v4/src/position-manager/interfaces/IGiverPositionManager.sol";
import {ITakerPositionManager} from "aave-v4/src/position-manager/interfaces/ITakerPositionManager.sol";
import {IPriceOracle} from "aave-v4/src/spoke/interfaces/IPriceOracle.sol";
import {ISpoke, ReserveFlags} from "aave-v4/src/spoke/interfaces/ISpoke.sol";
import {ReserveFlagsMap} from "aave-v4/src/spoke/libraries/ReserveFlagsMap.sol";

import {IFlashLoanRouter} from "../../lib/flash-loan-router/src/interface/IFlashLoanRouter.sol";
import {ComposableCoW} from "../ComposableCoW.sol";
import {IConditionalOrder} from "../interfaces/IConditionalOrder.sol";
import {BaseAavePositionProtector} from "./BaseAavePositionProtector.sol";

/// @notice Protects a borrower-selected collateral and debt pair on one Spoke.
/// @dev The borrower enables Giver and Taker on the Spoke and approves collateral withdrawal on Taker.
contract AaveV4PositionProtector is BaseAavePositionProtector {
    ISpoke private immutable spoke;
    IGiverPositionManager private immutable giver;
    ITakerPositionManager private immutable taker;

    struct Reserve {
        uint256 id;
        uint8 decimals;
        bool listed;
    }

    mapping(IERC20 => Reserve) private reserves;

    constructor(
        IConditionalOrder handler_,
        ComposableCoW registry,
        IPool flashLender,
        IFlashLoanRouter router_,
        ISpoke spoke_,
        IGiverPositionManager giver_,
        ITakerPositionManager taker_,
        uint256[] memory reserveIds
    ) BaseAavePositionProtector(handler_, registry, flashLender, router_, address(giver_)) {
        if (
            reserveIds.length < 2 || address(spoke_).code.length == 0 || address(giver_).code.length == 0
                || address(taker_).code.length == 0 || !spoke_.isPositionManagerActive(address(giver_))
                || !spoke_.isPositionManagerActive(address(taker_)) || !giver_.isSpokeRegistered(address(spoke_))
                || !taker_.isSpokeRegistered(address(spoke_))
        ) revert InvalidDeployment();

        for (uint256 i; i < reserveIds.length; ++i) {
            uint256 id = reserveIds[i];
            ISpoke.Reserve memory reserve = spoke_.getReserve(id);
            IERC20 asset = IERC20(reserve.underlying);
            if (address(asset) == address(0) || reserves[asset].listed) revert InvalidDeployment();
            reserves[asset] = Reserve(id, reserve.decimals, true);
        }

        spoke = spoke_;
        giver = giver_;
        taker = taker_;
    }

    function _position(address borrower, RuleConfig storage config, bool forQuote)
        internal
        view
        override
        returns (Position memory p)
    {
        uint256 collateralReserveId;
        uint256 debtReserveId;
        {
            ISpoke.UserAccountData memory account = spoke.getUserAccountData(borrower);
            p.healthFactor = account.healthFactor;
            Reserve storage collateral = reserves[config.collateralToken];
            Reserve storage debt = reserves[config.debtToken];
            if (
                !collateral.listed || !debt.listed || config.collateralToken == config.debtToken
                    || account.activeCollateralCount != 1 || account.borrowCount != 1
            ) return p;
            collateralReserveId = collateral.id;
            debtReserveId = debt.id;

            (bool collateralEnabled,) = spoke.getUserReserveStatus(collateralReserveId, borrower);
            (, bool borrowing) = spoke.getUserReserveStatus(debtReserveId, borrower);
            if (!collateralEnabled || !borrowing) return p;
        }

        ISpoke.UserPosition memory supply = spoke.getUserPosition(collateralReserveId, borrower);
        if (supply.suppliedShares == 0) return p;
        ISpoke.Reserve memory reserve = spoke.getReserve(collateralReserveId);
        uint32 latest = reserve.dynamicConfigKey;
        p.liquidationThreshold = spoke.getDynamicReserveConfig(collateralReserveId, latest).collateralFactor;
        // The current HF uses the position's saved factor. Withdrawal refreshes it to the latest one.
        if (p.liquidationThreshold == 0) return p;

        uint32 saved = supply.dynamicConfigKey;
        if (saved != latest && spoke.getDynamicReserveConfig(collateralReserveId, saved).collateralFactor == 0) {
            return p;
        }

        p.debt = spoke.getUserTotalDebt(debtReserveId, borrower);
        if (spoke.isPositionManager(borrower, address(giver)) && spoke.isPositionManager(borrower, address(taker))) {
            p.allowance = _withdrawAllowance(borrower, collateralReserveId);
        }

        // Read the balance and rounding buffer only for quotes that pass these checks.
        if (
            forQuote && _canQuote(p, config)
                && _flashLoanAvailable(pool.getConfiguration(address(config.collateralToken)))
                && giver.isSpokeRegistered(address(spoke)) && taker.isSpokeRegistered(address(spoke))
                && _canOperateReserve(reserve) && _canOperateReserve(spoke.getReserve(debtReserveId))
        ) {
            p.collateralBalance = spoke.getUserSuppliedAssets(collateralReserveId, borrower);
            // Bound the withdrawal debit by the value of one share rounded up.
            p.collateralDebitBuffer = reserve.hub.previewAddByShares(reserve.assetId, 1);
        }
    }

    function _canOperateReserve(ISpoke.Reserve memory reserve) private view returns (bool) {
        if ((ReserveFlags.unwrap(reserve.flags) & ReserveFlagsMap.PAUSED_MASK) != 0) return false;
        IHub.SpokeConfig memory config = IHub(address(reserve.hub)).getSpokeConfig(reserve.assetId, address(spoke));
        return config.active && !config.halted;
    }

    function _healthFactor(address borrower) internal view override returns (uint256) {
        return spoke.getUserAccountData(borrower).healthFactor;
    }

    function _debtBalance(address borrower, RuleConfig storage config) internal view override returns (uint256) {
        return spoke.getUserTotalDebt(reserves[config.debtToken].id, borrower);
    }

    function _repayDebt(address borrower, RuleConfig storage config, uint256 repayment) internal override {
        giver.repayOnBehalfOf(address(spoke), reserves[config.debtToken].id, repayment, borrower);
    }

    function _marketPrices(IERC20 collateralToken, IERC20 debtToken)
        internal
        view
        override
        returns (uint256, uint256, uint8, uint8)
    {
        Reserve storage collateral = reserves[collateralToken];
        Reserve storage debt = reserves[debtToken];
        IPriceOracle oracle = IPriceOracle(spoke.ORACLE());
        uint256 collateralPrice = oracle.getReservePrice(collateral.id);
        uint256 debtPrice = oracle.getReservePrice(debt.id);
        if (collateralPrice == 0 || debtPrice == 0) revert InvalidOraclePrice();
        return (collateralPrice, debtPrice, collateral.decimals, debt.decimals);
    }

    function _withdrawCollateral(address borrower, RuleConfig storage config, uint256 repayment)
        internal
        override
        returns (uint256 spent)
    {
        uint256 collateralReserveId = reserves[config.collateralToken].id;
        uint256 allowance = _withdrawAllowance(borrower, collateralReserveId);
        uint256 beforeAssets = spoke.getUserSuppliedAssets(collateralReserveId, borrower);
        (, uint256 received) = taker.withdrawOnBehalfOf(address(spoke), collateralReserveId, repayment, borrower);
        if (received != repayment) revert UnexpectedTokenMovement();

        // A share burn can debit slightly more supplied assets than the underlying sent by Taker.
        spent = beforeAssets - spoke.getUserSuppliedAssets(collateralReserveId, borrower);
        if (spent > config.cap) revert CollateralCapExceeded();
        if (spent > allowance) revert InsufficientCollateralAllowance();
    }

    function _withdrawAllowance(address borrower, uint256 collateralReserveId) private view returns (uint256) {
        return taker.withdrawAllowance(address(spoke), collateralReserveId, borrower, address(this));
    }
}
