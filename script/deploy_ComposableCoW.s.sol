// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Script.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";

contract DeployComposableCoW is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address settlement = vm.envAddress("SETTLEMENT");
        vm.startBroadcast(deployerPrivateKey);

        new ComposableCoW(settlement);

        vm.stopBroadcast();
    }
}
