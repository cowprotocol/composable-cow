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
import {ComposableCowPoller, ICowShedFactory} from "../src/types/ComposableCowPoller.sol";

import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";

/// Deploy every contract, reusing the ones in `canonical/` unless `CANONICAL=false`.
/// Contracts already on the chain are skipped, so a partial run can be resumed by repeating it.
/// See "Deploy newer contracts" in the readme.
contract DeployAll is DeployScript {
    function run() external {
        bytes32 salt = deploymentSalt();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // `composableCoWAddress()` is the one `dev/deploy-canonical.sh` puts on the chain.
        ComposableCoW composableCow = vm.envOr("CANONICAL", true) ? composableCoWAddress() : deployLegacy(salt);

        // Not in `canonical/`, so deployed in both modes.
        ICowShedFactory cowShedFactory = cowShedFactoryAddress();
        bytes memory poller =
            abi.encodePacked(type(ComposableCowPoller).creationCode, abi.encode(composableCow, cowShedFactory));
        if (pending("ComposableCowPoller", salt, poller)) {
            new ComposableCowPoller{salt: salt}(composableCow, cowShedFactory);
        }

        vm.stopBroadcast();
    }

    /// Compiles the contracts in `canonical/` from source, landing on different addresses.
    function deployLegacy(bytes32 salt) private returns (ComposableCoW composableCow) {
        address settlement = settlementAddress();

        if (pending("ExtensibleFallbackHandler", salt, type(ExtensibleFallbackHandler).creationCode)) {
            new ExtensibleFallbackHandler{salt: salt}();
        }

        bytes memory initcode = abi.encodePacked(type(ComposableCoW).creationCode, abi.encode(settlement));
        composableCow = ComposableCoW(create2Address(salt, initcode));
        if (pending("ComposableCoW", salt, initcode)) {
            new ComposableCoW{salt: salt}(settlement);
        }

        if (pending("TWAP", salt, abi.encodePacked(type(TWAP).creationCode, abi.encode(composableCow)))) {
            new TWAP{salt: salt}(composableCow);
        }
        if (pending("GoodAfterTime", salt, type(GoodAfterTime).creationCode)) {
            new GoodAfterTime{salt: salt}();
        }
        if (pending("PerpetualStableSwap", salt, type(PerpetualStableSwap).creationCode)) {
            new PerpetualStableSwap{salt: salt}();
        }
        if (pending("TradeAboveThreshold", salt, type(TradeAboveThreshold).creationCode)) {
            new TradeAboveThreshold{salt: salt}();
        }
        if (pending("StopLoss", salt, type(StopLoss).creationCode)) {
            new StopLoss{salt: salt}();
        }
        if (pending("CurrentBlockTimestampFactory", salt, type(CurrentBlockTimestampFactory).creationCode)) {
            new CurrentBlockTimestampFactory{salt: salt}();
        }
    }
}
