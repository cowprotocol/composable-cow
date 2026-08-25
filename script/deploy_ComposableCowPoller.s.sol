// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";
import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";

contract DeployComposableCowPoller is DeployScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = deploymentSalt();
        ComposableCoW composableCow = composableCoWAddress();
        bytes memory initcode = abi.encodePacked(type(ComposableCowPoller).creationCode, abi.encode(composableCow));

        vm.startBroadcast(deployerPrivateKey);

        if (pending("ComposableCowPoller", salt, initcode)) {
            new ComposableCowPoller{salt: salt}(composableCow);
        }

        vm.stopBroadcast();
    }
}
