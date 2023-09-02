// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IExpectedOutCalculator {
    function getExpectedOut(uint256 _amountIn, IERC20 _fromToken, IERC20 _toToken, bytes calldata _data)
        external
        view
        returns (uint256);
}
