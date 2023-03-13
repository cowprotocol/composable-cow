// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 token for testing.
/// @author mfw78 <mfw78@rndlabs.xyz>
contract MockERC20 is ERC20 {
    /// @dev Initializes a new mock ERC20 token. No tokens are minted, makes use instead
    /// of `vm.deal` in tests.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
}

/// @title Tokens - A helper contract for local integration testing.
/// @author mfw78 <mfw78@rndlabs.xyz>
abstract contract Tokens {
    IERC20 public token0;
    IERC20 public token1;
    IERC20 public token2;

    constructor() {
        token0 = IERC20(address(new MockERC20("Token 0", "T0")));
        token1 = IERC20(address(new MockERC20("Token 1", "T1")));
        token2 = IERC20(address(new MockERC20("Token 2", "T2")));
    }
}
