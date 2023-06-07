// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/**
 * @title IValueFactory - An interface for on-chain value determination
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Designed to be used with Safe + ExtensibleFallbackHandler + ComposableCoW
 */
interface IValueFactory {
    /**
     * Return a value at the time of the call
     * @param data Implementation specific off-chain data
     * @return value The value at the time of the call
     */
    function getValue(bytes calldata data) external view returns (bytes32 value);
}
