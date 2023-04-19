// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Safe} from "safe/Safe.sol";
import {Enum} from "safe/common/Enum.sol";
import {SafeProxyFactory} from "safe/proxies/SafeProxyFactory.sol";
import {CompatibilityFallbackHandler} from "safe/handler/CompatibilityFallbackHandler.sol";
import {MultiSend} from "safe/libraries/MultiSend.sol";
import {SignMessageLib} from "safe/libraries/SignMessageLib.sol";
import "safe/handler/ExtensibleFallbackHandler.sol";

import {SafeLib} from "../libraries/SafeLib.t.sol";
import {TestAccount, TestAccountLib} from "../libraries/TestAccountLib.t.sol";

/**
 * @title Safe - A helper contract for local integration testing with `Safe`.
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract SafeHelper {
    using SafeLib for Safe;

    Safe public singleton;
    SafeProxyFactory public factory;
    CompatibilityFallbackHandler public handler;
    ExtensibleFallbackHandler public eHandler;
    MultiSend public multisend;
    SignMessageLib public signMessageLib;

    constructor() {
        // Deploy the contracts
        singleton = new Safe();
        factory = new SafeProxyFactory();
        handler = new CompatibilityFallbackHandler();
        // extensible fallback handler
        eHandler = new ExtensibleFallbackHandler();
        multisend = new MultiSend();
        signMessageLib = new SignMessageLib();
    }

    /**
     * @dev Override this function to return the signers for the `Safe` instance.
     */
    function signers() internal view virtual returns (TestAccount[] memory);

    function setFallbackHandler(Safe safe, address _handler) internal {
        // do the transaction
        safe.execute(
            address(safe),
            0,
            abi.encodeWithSelector(safe.setFallbackHandler.selector, _handler),
            Enum.Operation.Call,
            signers()
        );
    }

    function setSafeMethodHandler(Safe safe, bytes4 selector, bool isStatic, address _handler) internal {
        bytes32 encodedHandler = MarshalLib.encode(isStatic, _handler);
        safe.execute(
            address(safe),
            0,
            abi.encodeWithSelector(FallbackHandler.setSafeMethod.selector, selector, encodedHandler),
            Enum.Operation.Call,
            signers()
        );
    }

    function safeSignMessage(Safe safe, bytes memory message) internal {
        safe.execute(
            address(signMessageLib),
            0,
            abi.encodeWithSelector(signMessageLib.signMessage.selector, message),
            Enum.Operation.DelegateCall,
            signers()
        );
    }
}
