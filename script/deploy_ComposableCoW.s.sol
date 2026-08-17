// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";

contract DeployComposableCoW is DeployScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address settlement = settlementAddress();
        vm.startBroadcast(deployerPrivateKey);

        new ComposableCoW{salt: deploymentSalt()}(settlement);

        vm.stopBroadcast();
    }
}
