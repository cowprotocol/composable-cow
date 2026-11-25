// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

import {FeeTokenSwap} from "../src/types/FeeTokenSwap.sol";

contract DeployFeeTokenSwap is DeployScript {
    function run() external {
        bytes32 salt = deploymentSalt();
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        if (pending("FeeTokenSwap", salt, type(FeeTokenSwap).creationCode)) {
            new FeeTokenSwap{salt: salt}();
        }

        vm.stopBroadcast();
    }
}
