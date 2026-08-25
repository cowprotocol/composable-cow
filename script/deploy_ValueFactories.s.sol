// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";

contract DeployValueFactories is DeployScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = deploymentSalt();

        vm.startBroadcast(deployerPrivateKey);

        if (pending("CurrentBlockTimestampFactory", salt, type(CurrentBlockTimestampFactory).creationCode)) {
            new CurrentBlockTimestampFactory{salt: salt}();
        }

        vm.stopBroadcast();
    }
}
