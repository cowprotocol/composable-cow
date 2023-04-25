// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "../interfaces/ISwapGuard.sol";

/**
 * @title An abstract base contract for Swap Guards to inherit from
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract BaseSwapGuard is ISwapGuard {
    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return interfaceId == type(ISwapGuard).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
