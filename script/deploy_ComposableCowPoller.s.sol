// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";
import {ComposableCowPoller, ICowShedFactory} from "../src/types/ComposableCowPoller.sol";

contract DeployComposableCowPoller is Script {
    error InvalidComposableCow();
    error InvalidCowShedFactory();

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address composableCow = vm.envAddress("COMPOSABLE_COW");
        address cowShedFactory = vm.envAddress("COW_SHED_FACTORY");
        if (composableCow.code.length == 0) revert InvalidComposableCow();
        if (cowShedFactory.code.length == 0) revert InvalidCowShedFactory();

        vm.startBroadcast(deployerPrivateKey);
        ComposableCowPoller poller =
            new ComposableCowPoller(ComposableCoW(composableCow), ICowShedFactory(cowShedFactory));
        vm.stopBroadcast();

        console.log("ComposableCowPoller address");
        console.logAddress(address(poller));
    }
}
