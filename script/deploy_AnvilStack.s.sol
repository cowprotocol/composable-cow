// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

// CoW Protocol
import {IVault} from "cowprotocol/contracts/interfaces/IVault.sol";
import {GPv2Settlement} from "cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2AllowListAuthentication} from "cowprotocol/contracts/GPv2AllowListAuthentication.sol";
import {GPv2Authentication} from "cowprotocol/contracts/interfaces/GPv2Authentication.sol";

// Safe contracts
import {Safe} from "safe/Safe.sol";
import {Enum} from "safe/common/Enum.sol";
import {SafeProxyFactory, SafeProxy} from "safe/proxies/SafeProxyFactory.sol";
import {CompatibilityFallbackHandler} from "safe/handler/CompatibilityFallbackHandler.sol";
import {MultiSend} from "safe/libraries/MultiSend.sol";
import {SignMessageLib} from "safe/libraries/SignMessageLib.sol";
import {ExtensibleFallbackHandler} from "safe/handler/ExtensibleFallbackHandler.sol";
import {SafeLib} from "../test/libraries/SafeLib.t.sol";

// Composable CoW
import {ComposableCoW} from "../src/ComposableCoW.sol";
import {TWAP} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";

contract DeployAnvilStack is Script {
    // --- constants
    uint256 constant PAUSE_WINDOW_DURATION = 7776000;
    uint256 constant BUFFER_PERIOD_DURATION = 2592000;

    // --- cow protocol contract stack
    IVault public vault;
    GPv2Settlement public settlement;
    address public relayer;

    // --- safe contract stack
    Safe public singleton;
    SafeProxyFactory public factory;
    CompatibilityFallbackHandler public handler;
    ExtensibleFallbackHandler public eHandler;
    MultiSend public multisend;
    SignMessageLib public signMessageLib;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // deploy the CoW Protocol stack
        // **NOTE**: Requires a higher code size limit due to the Balancer vault
        // `anvil --code-size-limit 50000`
        deployCowProtocolStack(vm.addr(deployerPrivateKey));

        // deploy the Safe contract stack
        deploySafeStack();

        // deploy the Safe
        SafeProxy proxy = deploySafe(vm.addr(deployerPrivateKey));

        // deploy the Composable CoW
        ComposableCoW composableCow = new ComposableCoW(address(settlement));
        new TWAP(composableCow);
        new GoodAfterTime();
        new PerpetualStableSwap();
        new TradeAboveThreshold();

        vm.stopBroadcast();

        console.log("Safe address");
        console.logAddress(address(proxy));
    }

    function deploySafe(address owner) internal returns (SafeProxy proxy) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        proxy = SafeLib.createSafe(factory, singleton, owners, 1, address(eHandler), 0);
    }

    function deploySafeStack() internal {
        // Deploy the contracts
        singleton = new Safe();
        factory = new SafeProxyFactory();
        handler = new CompatibilityFallbackHandler();
        // extensible fallback handler
        eHandler = new ExtensibleFallbackHandler();
        multisend = new MultiSend();
        signMessageLib = new SignMessageLib();
    }

    function deployCowProtocolStack(address all) internal {
        vault = IVault(makeAddr("fakeVault"));

        // deploy the allow list manager
        GPv2AllowListAuthentication allowList = new GPv2AllowListAuthentication();
        allowList.initializeManager(all);

        /// @dev the settlement contract is the main entry point for the CoW Protocol
        settlement = new GPv2Settlement(allowList, vault);

        /// @dev the relayer is the account authorized to spend the user's tokens
        relayer = address(settlement.vaultRelayer());

        // authorize the solver
        allowList.addSolver(all);
    }
}
