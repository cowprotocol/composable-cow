// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script} from "forge-std/Script.sol";

import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";

// Safe contracts
import {Safe} from "safe/Safe.sol";
import {Enum} from "safe/common/Enum.sol";
import {SafeProxyFactory} from "safe/proxies/SafeProxyFactory.sol";
import {CompatibilityFallbackHandler} from "safe/handler/CompatibilityFallbackHandler.sol";
import {MultiSend} from "safe/libraries/MultiSend.sol";
import {SignMessageLib} from "safe/libraries/SignMessageLib.sol";
import {ExtensibleFallbackHandler} from "safe/handler/ExtensibleFallbackHandler.sol";
import {SafeLib} from "../test/libraries/SafeLib.t.sol";

// Composable CoW
import {IConditionalOrder, ComposableCoW} from "../src/ComposableCoW.sol";
import {TWAP, TWAPOrder} from "../src/types/twap/TWAP.sol";

/**
 * @title Submit a single order to ComposableCoW
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
contract SubmitSingleOrder is Script {
    using SafeLib for Safe;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        Safe safe = Safe(payable(vm.envAddress("SAFE")));
        TWAP twap = TWAP(vm.envAddress("TWAP"));
        ComposableCoW composableCow = ComposableCoW(vm.envAddress("COMPOSABLE_COW"));

        TWAPOrder.Data memory twapOrder = TWAPOrder.Data({
            sellToken: IERC20(address(1)),
            buyToken: IERC20(address(2)),
            receiver: address(0),
            partSellAmount: 10,
            minPartLimit: 1,
            t0: block.timestamp,
            n: 10,
            t: 120,
            span: 0,
            appData: keccak256("forge.scripts.twap")
        });

        vm.startBroadcast(deployerPrivateKey);

        // call to ComposableCoW to submit a single order
        safe.executeSingleOwner(
            address(composableCow),
            0,
            abi.encodeCall(
                composableCow.create,
                (
                    IConditionalOrder.ConditionalOrderParams({
                        handler: IConditionalOrder(twap),
                        salt: keccak256(abi.encodePacked("TWAP")),
                        staticInput: abi.encode(twapOrder)
                    }),
                    true
                )
            ),
            Enum.Operation.Call,
            vm.addr(deployerPrivateKey)
        );

        vm.stopBroadcast();
    }
}
