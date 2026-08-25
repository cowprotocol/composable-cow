// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {DeployScript} from "./DeployScript.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";

contract DeployComposableCoW is DeployScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = deploymentSalt();
        address settlement = settlementAddress();
        bytes memory initcode = abi.encodePacked(type(ComposableCoW).creationCode, abi.encode(settlement));

        vm.startBroadcast(deployerPrivateKey);

        if (pending("ComposableCoW", salt, initcode)) {
            new ComposableCoW{salt: salt}(settlement);
        }

        vm.stopBroadcast();
    }
}
