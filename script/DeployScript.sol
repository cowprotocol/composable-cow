// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

import {ComposableCoW} from "../src/ComposableCoW.sol";
import {ICowShedFactory} from "../src/types/ComposableCowPoller.sol";
import {CoWSettlement} from "../src/vendored/CoWSettlement.sol";

abstract contract DeployScript is Script {
    /// The EIP-712 domain `GPv2Signing` builds its separator from.
    bytes32 private constant DOMAIN_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant DOMAIN_NAME = keccak256("Gnosis Protocol");
    bytes32 private constant DOMAIN_VERSION = keccak256("v2");

    /// The proxy `forge script` routes `CREATE2` through, so an address depends only on the salt
    /// and the initcode, never on who runs the script.
    address private constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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

    /// Where `new C{salt: salt}(args)` lands, for `initcode` = creation code followed by the
    /// encoded constructor arguments.
    function create2Address(bytes32 salt, bytes memory initcode) internal pure returns (address) {
        bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_PROXY, salt, keccak256(initcode)));
        return address(uint160(uint256(digest)));
    }

    /// Logs the contract and reports whether it still has to be deployed. `CREATE2` onto an address
    /// that already holds code reverts with no message and takes the rest of the run with it, so
    /// every deployment is guarded by this and a re-run turns into a no-op.
    function pending(string memory name, bytes32 salt, bytes memory initcode) internal view returns (bool) {
        address addr = create2Address(salt, initcode);
        bool deployed = addr.code.length > 0;
        console.log(deployed ? "present  " : "deploying", name, addr);
        return !deployed;
    }

    /// The `GPv2Settlement` from `SETTLEMENT`. `ComposableCoW` pins this immutably, so check it.
    function settlementAddress() internal returns (address settlement) {
        // `vm.envAddress` reverts without a message, and every script reaches this one, including
        // the ones whose own documented invocation only mentions `COMPOSABLE_COW`.
        settlement = vm.envOr("SETTLEMENT", address(0));
        require(settlement != address(0), "SETTLEMENT is not set: see .env.example");

        // Self-verifying: the separator commits to the chain and to the address it lives at, so a
        // contract can only match at the address we are about to deploy against.
        (bool ok, bytes32 separator) = tryBytes32(settlement, abi.encodeCall(CoWSettlement.domainSeparator, ()));
        require(ok && separator == settlementSeparator(settlement), "SETTLEMENT is not a GPv2Settlement here");
    }

    /// The `ComposableCoW` from `COMPOSABLE_COW`. `ComposableCowPoller` pins this immutably.
    function composableCoWAddress() internal returns (ComposableCoW composableCow) {
        address addr = vm.envOr("COMPOSABLE_COW", address(0));
        require(addr != address(0), "COMPOSABLE_COW is not set: see .env.example");
        require(
            addr.code.length > 0,
            "ComposableCoW is not deployed on this chain: run dev/deploy-canonical.sh first, or set CANONICAL=false"
        );

        // Resolved up front so a bad `SETTLEMENT`, including the two addresses swapped over, reports
        // itself rather than reaching the caller as a separator mismatch blamed on `COMPOSABLE_COW`.
        bytes32 expected = settlementSeparator(settlementAddress());

        // Probe a selector `GPv2Settlement` lacks first: swapping the two addresses is an easy typo,
        // and the settlement would otherwise match its own separator below.
        // `singleOrders` is a public mapping, so it has no callable member for `abi.encodeCall`.
        (bool shaped, bytes memory unset) =
            addr.staticcall(abi.encodeWithSignature("singleOrders(address,bytes32)", address(0), bytes32(0)));

        // `ComposableCoW` copies its separator from the settlement it was built against.
        (bool ok, bytes32 separator) = tryBytes32(addr, abi.encodeCall(CoWSettlement.domainSeparator, ()));
        require(
            shaped && unset.length == 32 && !abi.decode(unset, (bool)) && ok && separator == expected,
            "COMPOSABLE_COW is not a ComposableCoW for SETTLEMENT on this chain"
        );

        composableCow = ComposableCoW(addr);
    }

    /// The CowShed factory from `COW_SHED_FACTORY`. `ComposableCowPoller` pins this immutably.
    function cowShedFactoryAddress() internal returns (ICowShedFactory factory) {
        address addr = vm.envOr("COW_SHED_FACTORY", address(0));
        require(addr != address(0), "COW_SHED_FACTORY is not set: see .env.example");

        // The poller's constructor only checks for code. Probe `proxyOf` so a wrong address is named
        // here rather than surfacing later as an `UnauthorizedShed` on every `FromShed` call.
        (bool ok, bytes memory data) = addr.staticcall(abi.encodeCall(ICowShedFactory.proxyOf, (address(0))));
        require(
            ok && data.length == 32 && abi.decode(data, (address)) != address(0),
            "COW_SHED_FACTORY is not a CowShed factory here"
        );

        factory = ICowShedFactory(addr);
    }

    /// The separator a `GPv2Settlement` at `settlement` must have on this chain.
    function settlementSeparator(address settlement) private view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPE_HASH, DOMAIN_NAME, DOMAIN_VERSION, block.chainid, settlement));
    }

    /// A `bytes32` view call that reports failure instead of reverting when the callee has no such
    /// function, so the caller can raise its own message.
    function tryBytes32(address target, bytes memory call) private view returns (bool ok, bytes32 value) {
        bytes memory data;
        (ok, data) = target.staticcall(call);
        if (!ok || data.length != 32) return (false, bytes32(0));
        value = abi.decode(data, (bytes32));
    }
}
