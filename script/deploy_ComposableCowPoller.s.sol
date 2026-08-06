// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {console} from "forge-std/Script.sol";
import {DeployScript} from "./DeployScript.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";
import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";

contract DeployComposableCowPoller is DeployScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address composableCow = vm.envAddress("COMPOSABLE_COW");

        vm.startBroadcast(deployerPrivateKey);

        ComposableCowPoller poller = new ComposableCowPoller{salt: deploymentSalt()}(ComposableCoW(composableCow));

        vm.stopBroadcast();

        console.log("ComposableCowPoller address");
        console.logAddress(address(poller));
    }
}
