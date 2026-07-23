// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";
import {ComposableCowPoller, ICowShedFactory} from "../src/types/ComposableCowPoller.sol";

contract DeployComposableCowPoller is Script {
    uint256 internal constant GNOSIS_CHAIN_ID = 100;
    address internal constant GNOSIS_COMPOSABLE_COW = 0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74;
    address internal constant GNOSIS_COW_SHED_FACTORY = 0x4F4350bf2c74aaCD508D598a1ba94EF84378793d;

    error InvalidChain(uint256 chainId);
    error InvalidComposableCow();
    error InvalidCowShedFactory();

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address composableCow = vm.envAddress("COMPOSABLE_COW");
        address cowShedFactory = vm.envAddress("COW_SHED_FACTORY");
        if (block.chainid != GNOSIS_CHAIN_ID) revert InvalidChain(block.chainid);
        if (composableCow != GNOSIS_COMPOSABLE_COW || composableCow.code.length == 0) {
            revert InvalidComposableCow();
        }
        if (cowShedFactory != GNOSIS_COW_SHED_FACTORY || cowShedFactory.code.length == 0) {
            revert InvalidCowShedFactory();
        }

        vm.startBroadcast(deployerPrivateKey);
        ComposableCowPoller poller =
            new ComposableCowPoller(ComposableCoW(composableCow), ICowShedFactory(cowShedFactory));
        vm.stopBroadcast();

        console.log("ComposableCowPoller address");
        console.logAddress(address(poller));
    }
}
