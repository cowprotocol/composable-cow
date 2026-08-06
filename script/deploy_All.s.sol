// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

// ExtensibleFallbackHandler
import {ExtensibleFallbackHandler} from "../lib/safe/contracts/handler/ExtensibleFallbackHandler.sol";

// ComposableCoW
import {ComposableCoW} from "../src/ComposableCoW.sol";

// Order types
import {TWAP} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";
import {StopLoss} from "../src/types/StopLoss.sol";
import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";

// Value factories
import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";

/**
 * Deploy every contract in this repository.
 *
 * The older contracts can no longer be compiled to their official addresses (see
 * https://github.com/cowprotocol/composable-cow/issues/93), so by default this script does not
 * deploy them: it binds to the ones already on the chain, which `dev/deploy-canonical.sh` puts
 * there. Only the contracts that postdate that issue are deployed.
 *
 * Set `CANONICAL=false` to deploy everything from source instead. That produces a self-contained
 * stack at addresses that differ from every other chain, which is what you want on a devnet and
 * not what you want in production.
 */
contract DeployAll is DeployScript {
    // Address of `ComposableCoW` on every chain it has been deployed to.
    address private constant CANONICAL_COMPOSABLE_COW = 0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bool canonical = vm.envOr("CANONICAL", true);
        bytes32 salt = deploymentSalt();

        ComposableCoW composableCow;

        if (canonical) {
            composableCow = ComposableCoW(vm.envOr("COMPOSABLE_COW", CANONICAL_COMPOSABLE_COW));

            // Binding to an address with no contract would leave the poller pointing at nothing, so
            // fail here rather than deploy something unusable.
            require(
                address(composableCow).code.length > 0,
                "ComposableCoW is not deployed on this chain: run dev/deploy-canonical.sh first, or set CANONICAL=false"
            );

            vm.startBroadcast(deployerPrivateKey);
        } else {
            address settlement = vm.envAddress("SETTLEMENT");

            vm.startBroadcast(deployerPrivateKey);

            new ExtensibleFallbackHandler{salt: salt}();

            composableCow = new ComposableCoW{salt: salt}(settlement);

            new TWAP{salt: salt}(composableCow);
            new GoodAfterTime{salt: salt}();
            new PerpetualStableSwap{salt: salt}();
            new TradeAboveThreshold{salt: salt}();
            new StopLoss{salt: salt}();

            new CurrentBlockTimestampFactory{salt: salt}();
        }

        // Contracts added after the issue above. These compile to the same address on every chain,
        // so they are deployed in both modes.
        new ComposableCowPoller{salt: salt}(composableCow);

        vm.stopBroadcast();
    }
}
