// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {ReserveConfiguration} from "aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";
import {IHub} from "aave-v4/src/hub/interfaces/IHub.sol";
import {IGiverPositionManager} from "aave-v4/src/position-manager/interfaces/IGiverPositionManager.sol";
import {IPositionManagerBase} from "aave-v4/src/position-manager/interfaces/IPositionManagerBase.sol";
import {ITakerPositionManager} from "aave-v4/src/position-manager/interfaces/ITakerPositionManager.sol";
import {IPriceOracle} from "aave-v4/src/spoke/interfaces/IPriceOracle.sol";
import {ISpoke, IHubBase} from "aave-v4/src/spoke/interfaces/ISpoke.sol";

import {ICowSettlement, FlashLoanRouter} from "../../lib/flash-loan-router/src/FlashLoanRouter.sol";
import {AavePositionProtectionHandler} from "../../src/aave/AavePositionProtectionHandler.sol";
import {AaveV4PositionProtector} from "../../src/aave/AaveV4PositionProtector.sol";
import {IAavePositionProtector} from "../../src/aave/interfaces/IAavePositionProtector.sol";
import {ComposableCoW} from "../../src/ComposableCoW.sol";
import {CoWProtocol} from "../helpers/CoWProtocol.t.sol";

contract AaveV4PositionProtectorTest is CoWProtocol {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    uint256 private constant COLLATERAL = 0;
    uint256 private constant DEBT = 1;
    uint256 private constant OTHER_DEBT = 2;
    uint256 private constant HEALTH_FACTOR = 1.1e18;

    address private borrower;
    address private spoke;
    address private giver;
    address private taker;
    address private lender;
    AaveV4PositionProtector private protector;
    bytes32 private ruleId;

    function setUp() public override {
        super.setUp();
        borrower = makeAddr("borrower");
        spoke = _mockAddress("spoke");
        giver = _mockAddress("giver");
        taker = _mockAddress("taker");
        lender = _mockAddress("lender");
        address hub = _mockAddress("hub");
        address collateral = makeAddr("collateral");
        address debt = makeAddr("debt");

        vm.mockCall(spoke, abi.encodeCall(ISpoke.isPositionManagerActive, (giver)), abi.encode(true));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.isPositionManagerActive, (taker)), abi.encode(true));
        vm.mockCall(giver, abi.encodeCall(IPositionManagerBase.isSpokeRegistered, (spoke)), abi.encode(true));
        vm.mockCall(taker, abi.encodeCall(IPositionManagerBase.isSpokeRegistered, (spoke)), abi.encode(true));
        _mockReserve(hub, COLLATERAL, collateral, 18, 2000e8);
        _mockReserve(hub, DEBT, debt, 6, 1e8);
        _mockReserve(hub, OTHER_DEBT, makeAddr("other debt"), 8, 2e8);

        uint256[] memory reserveIds = new uint256[](3);
        reserveIds[0] = COLLATERAL;
        reserveIds[1] = DEBT;
        reserveIds[2] = OTHER_DEBT;
        protector = new AaveV4PositionProtector(
            new AavePositionProtectionHandler(),
            new ComposableCoW(address(settlement)),
            IPool(lender),
            new FlashLoanRouter(ICowSettlement(address(settlement))),
            ISpoke(spoke),
            IGiverPositionManager(giver),
            ITakerPositionManager(taker),
            reserveIds
        );

        vm.mockCall(lender, abi.encodeCall(IPool.FLASHLOAN_PREMIUM_TOTAL, ()), abi.encode(5));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.ORACLE, ()), abi.encode(spoke));

        ruleId = _register(borrower, COLLATERAL, DEBT, 1 ether, 1500e6);
        IAavePositionProtector.QuoteInputs memory inputs = protector.quoteInputs(ruleId);
        assertEq(inputs.flashLender, lender);
        assertEq(inputs.collateralDebitBuffer, 2);
    }

    function _register(address user, uint256 sellReserve, uint256 buyReserve, uint256 supplied, uint256 borrowed)
        private
        returns (bytes32)
    {
        ISpoke.Reserve memory collateral = ISpoke(spoke).getReserve(sellReserve);
        address debt = ISpoke(spoke).getReserve(buyReserve).underlying;
        uint256 cap = supplied / 10;

        ISpoke.UserAccountData memory account;
        account.healthFactor = HEALTH_FACTOR;
        account.activeCollateralCount = 1;
        account.borrowCount = 1;
        ISpoke.UserPosition memory position;
        position.suppliedShares = uint120(supplied);
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserAccountData, (user)), abi.encode(account));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserReserveStatus, (sellReserve, user)), abi.encode(true, false));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserReserveStatus, (buyReserve, user)), abi.encode(false, true));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserPosition, (sellReserve, user)), abi.encode(position));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserTotalDebt, (buyReserve, user)), abi.encode(borrowed));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserSuppliedAssets, (sellReserve, user)), abi.encode(supplied));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.isPositionManager, (user, giver)), abi.encode(true));
        vm.mockCall(spoke, abi.encodeCall(ISpoke.isPositionManager, (user, taker)), abi.encode(true));
        vm.mockCall(
            taker,
            abi.encodeCall(ITakerPositionManager.withdrawAllowance, (spoke, sellReserve, user, address(protector))),
            abi.encode(cap)
        );

        DataTypes.ReserveConfigurationMap memory configuration;
        configuration.setActive(true);
        configuration.setFlashLoanEnabled(true);
        vm.mockCall(lender, abi.encodeCall(IPool.getConfiguration, (collateral.underlying)), abi.encode(configuration));
        vm.mockCall(
            address(collateral.hub), abi.encodeCall(IHubBase.previewAddByShares, (collateral.assetId, 1)), abi.encode(2)
        );

        vm.prank(user);
        return protector.registerProtection(
            IAavePositionProtector.RuleConfig(
                IERC20(collateral.underlying),
                IERC20(debt),
                HEALTH_FACTOR,
                1.2e18,
                cap,
                uint32(block.timestamp + 1 hours),
                300
            )
        );
    }

    function test_twoBorrowersChooseDifferentPairsOnOneProtector() external {
        address otherBorrower = makeAddr("other borrower");
        bytes32 otherRuleId = _register(otherBorrower, DEBT, OTHER_DEBT, 2000e6, 750e8);
        IAavePositionProtector.QuoteInputs memory inputs = protector.quoteInputs(otherRuleId);

        assertEq(inputs.borrower, otherBorrower);
        assertEq(inputs.flashLender, lender);
        assertEq(inputs.debtAmount, 750e8);
        assertEq(inputs.collateralBalance, 2000e6);
        assertEq(inputs.collateralPrice, 1e8);
        assertEq(inputs.debtPrice, 2e8);
        assertEq(inputs.collateralDecimals, 6);
        assertEq(inputs.debtDecimals, 8);
        assertEq(protector.quoteInputs(ruleId).borrower, borrower);
    }

    function test_registerRejectsUnlistedCollateral() external {
        IAavePositionProtector.RuleConfig memory config = protector.quoteInputs(ruleId).config;
        vm.prank(borrower);
        protector.cancel(ruleId);

        config.collateralToken = IERC20(makeAddr("unlisted collateral"));
        vm.expectRevert(IAavePositionProtector.UnsupportedPosition.selector);
        vm.prank(borrower);
        protector.registerProtection(config);
    }

    function testFuzz_quoteUnavailableWhenPermissionOrMarketChanges(uint8 cause) external {
        cause = uint8(bound(cause, 0, 3));
        if (cause == 0) {
            vm.mockCall(taker, abi.encodeCall(IPositionManagerBase.isSpokeRegistered, (spoke)), abi.encode(false));
        } else if (cause == 1) {
            vm.mockCall(spoke, abi.encodeCall(ISpoke.isPositionManager, (borrower, taker)), abi.encode(false));
        } else if (cause == 2) {
            vm.mockCall(
                makeAddr("hub"),
                abi.encodeCall(IHub.getSpokeConfig, (COLLATERAL, spoke)),
                abi.encode(IHub.SpokeConfig(0, 0, 0, true, true))
            );
        } else {
            ISpoke.UserPosition memory position;
            position.suppliedShares = 1 ether;
            position.dynamicConfigKey = 1;
            vm.mockCall(spoke, abi.encodeCall(ISpoke.getUserPosition, (COLLATERAL, borrower)), abi.encode(position));
            vm.mockCall(
                spoke,
                abi.encodeCall(ISpoke.getDynamicReserveConfig, (COLLATERAL, 1)),
                abi.encode(ISpoke.DynamicReserveConfig(0, 0, 0))
            );
        }
        assertEq(protector.quoteInputs(ruleId).flashLender, address(0));
    }

    function _mockAddress(string memory label) private returns (address target) {
        target = makeAddr(label);
        vm.etch(target, hex"00");
    }

    function _mockReserve(address hub, uint256 id, address asset, uint8 decimals, uint256 price) private {
        ISpoke.Reserve memory reserve;
        reserve.underlying = asset;
        reserve.hub = IHubBase(hub);
        reserve.assetId = uint16(id);
        reserve.decimals = decimals;
        vm.mockCall(spoke, abi.encodeCall(ISpoke.getReserve, (id)), abi.encode(reserve));
        vm.mockCall(
            spoke,
            abi.encodeCall(ISpoke.getDynamicReserveConfig, (id, 0)),
            abi.encode(ISpoke.DynamicReserveConfig(8250, 0, 0))
        );
        vm.mockCall(spoke, abi.encodeCall(IPriceOracle.getReservePrice, (id)), abi.encode(price));
        vm.mockCall(
            hub, abi.encodeCall(IHub.getSpokeConfig, (id, spoke)), abi.encode(IHub.SpokeConfig(0, 0, 0, true, false))
        );
    }
}
