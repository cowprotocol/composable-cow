// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script} from "forge-std/Script.sol";

abstract contract DeployScript is Script {
    /// `CREATE2` salt from `SALT`, laid out like a Solidity string literal so `SALT=v1.1.0` and
    /// `{salt: "v1.1.0"}` agree. See `.env.example`.
    function deploymentSalt() internal returns (bytes32 salt) {
        string memory text = vm.envOr("SALT", string("v1.0.0"));
        uint256 length = bytes(text).length;
        require(length <= 32, "SALT must be at most 32 bytes");

        assembly {
            salt := mload(add(text, 32))
        }

        // `mload` reads a full word, so discard whatever followed the string in memory.
        salt &= bytes32(type(uint256).max << (8 * (32 - length)));
    }
}
