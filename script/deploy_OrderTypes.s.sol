// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Script.sol";

import "../src/ComposableCoW.sol";

import {TWAP} from "../src/types/twap/TWAP.sol";
import {GoodAfterTime} from "../src/types/GoodAfterTime.sol";
import {PerpetualStableSwap} from "../src/types/PerpetualStableSwap.sol";
import {TradeAboveThreshold} from "../src/types/TradeAboveThreshold.sol";

contract DeployOrderTypes is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address composableCow = vm.envAddress("COMPOSABLE_COW");
        vm.startBroadcast(deployerPrivateKey);

        new TWAP(ComposableCoW(composableCow));
        new GoodAfterTime();
        new PerpetualStableSwap();
        new TradeAboveThreshold();

        vm.stopBroadcast();
    }
}
