// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Script.sol";

import {ExtensibleFallbackHandler} from "safe/handler/ExtensibleFallbackHandler.sol";

contract DeployExtensibleFallbackHandler is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        new ExtensibleFallbackHandler();

        vm.stopBroadcast();
    }
}
