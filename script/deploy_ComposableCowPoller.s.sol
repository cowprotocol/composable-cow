// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";
import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";

contract DeployComposableCowPoller is Script {
    error InvalidComposableCow();

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address composableCow = vm.envAddress("COMPOSABLE_COW");
        if (composableCow.code.length == 0) revert InvalidComposableCow();

        vm.startBroadcast(deployerPrivateKey);
        ComposableCowPoller poller = new ComposableCowPoller(ComposableCoW(composableCow));
        vm.stopBroadcast();

        console.log("ComposableCowPoller address");
        console.logAddress(address(poller));
    }
}
