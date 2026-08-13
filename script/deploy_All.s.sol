// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

import {ExtensibleFallbackHandler} from "../lib/safe/contracts/handler/ExtensibleFallbackHandler.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";

import {TWAP} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";
import {StopLoss} from "../src/types/StopLoss.sol";
import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";

import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";

/// Deploy every contract, reusing the ones in `canonical/` unless `CANONICAL=false`.
/// See "Deploy newer contracts" in the readme.
contract DeployAll is DeployScript {
    function run() external {
        bytes32 salt = deploymentSalt();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        ComposableCoW composableCow = vm.envOr("CANONICAL", true) ? existingComposableCoW() : deployLegacy(salt);

        // Not in `canonical/`, so deployed in both modes.
        new ComposableCowPoller{salt: salt}(composableCow);

        vm.stopBroadcast();
    }

    /// The `ComposableCoW` already on the chain, which `dev/deploy-canonical.sh` puts there.
    function existingComposableCoW() private returns (ComposableCoW composableCow) {
        composableCow = ComposableCoW(vm.envAddress("COMPOSABLE_COW"));
        require(
            address(composableCow).code.length > 0,
            "ComposableCoW is not deployed on this chain: run dev/deploy-canonical.sh first, or set CANONICAL=false"
        );
    }

    /// Compiles the contracts in `canonical/` from source, landing on different addresses.
    function deployLegacy(bytes32 salt) private returns (ComposableCoW composableCow) {
        address settlement = vm.envAddress("SETTLEMENT");

        new ExtensibleFallbackHandler{salt: salt}();
        composableCow = new ComposableCoW{salt: salt}(settlement);
        new TWAP{salt: salt}(composableCow);
        new GoodAfterTime{salt: salt}();
        new PerpetualStableSwap{salt: salt}();
        new TradeAboveThreshold{salt: salt}();
        new StopLoss{salt: salt}();
        new CurrentBlockTimestampFactory{salt: salt}();
    }
}
