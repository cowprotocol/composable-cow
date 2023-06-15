// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IValueFactory} from "../interfaces/IValueFactory.sol";

/**
 * @title CurrentBlockTimestampFactory - An on-chain value factory that returns the current block timestamp
 * @dev Designed to be used with Safe + ExtensibleFallbackHandler + ComposableCoW
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
contract CurrentBlockTimestampFactory is IValueFactory {
    function getValue(bytes calldata) external view override returns (bytes32) {
        return bytes32(block.timestamp);
    }
}
