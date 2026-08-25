// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {ComposableCoW} from "src/ComposableCoW.sol";
import {ERC1271Forwarder} from "src/ERC1271Forwarder.sol";

/// @dev A call a shed executes on its owner's behalf. Mirrors cow-shed's `Call` minus the
///      `allowFailure` / `isDelegateCall` flags, which nothing here exercises.
struct MockShedCall {
    address target;
    uint256 value;
    bytes callData;
}

/// @title MockCowShed - stand-in for a `COWShedForComposableCoW` proxy.
/// @dev cow-shed cannot be a submodule here: it needs solc `^0.8.25`, and this repo pins 0.8.19 to
///      keep every `CREATE2` address reproducible. So these mocks reproduce the properties
///      `ComposableCowPoller` and settlement depend on:
///
///      1. the shed lives at an address `CREATE2`-derived from its factory and its owner alone,
///      2. it executes owner-authorized calls (`executeHooks`) or, if one is set, calls from a
///         trusted executor with no authorization at all (`trustedExecuteHooks`), and
///      3. it validates CoW orders under ERC-1271 by forwarding to `ComposableCoW`.
///
///      Property 3 is the real thing, not a mock: upstream's `COWShedForComposableCoW` is `COWShed`
///      plus this repo's own `ERC1271Forwarder`, which is inherited here.
///
///      The real thing splits proxy and implementation. That split is collapsed here because the
///      poller never derives an address itself — it asks `proxyOf` and compares — so the split adds
///      no coverage. Both constructor arguments land in the init code and so in the derived address,
///      as upstream's `(implementation, owner)` does: a shed's address pins its `ComposableCoW`
///      either way, since upstream holds that as an immutable of the implementation.
contract MockCowShed is ERC1271Forwarder {
    /// @notice The shed's owner and admin. Immutable, as in `COWShedProxy`.
    address public immutable OWNER;

    /// @notice May call `trustedExecuteHooks` without any signature.
    address public trustedExecutor;

    /// @notice Consumed hook nonces.
    mapping(bytes32 => bool) public nonces;

    error AlreadyInitialized();
    error InvalidSignature();
    error NonceReused();
    error OnlyTrustedRole();
    error CallReverted(uint256 index);

    constructor(ComposableCoW _composableCow, address owner) ERC1271Forwarder(_composableCow) {
        OWNER = owner;
    }

    /// @dev The factory calls this at deployment, atomically, so the executor cannot be front-run.
    function initialize(address executor) external {
        if (trustedExecutor != address(0)) revert AlreadyInitialized();
        trustedExecutor = executor;
    }

    /// @notice The digest the owner signs to authorize `calls`.
    /// @dev Bound to this shed and chain, so a signature cannot be replayed onto another shed.
    function hashToSign(MockShedCall[] calldata calls, bytes32 nonce) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, keccak256(abi.encode(calls)), nonce));
    }

    /// @notice Execute calls the owner signed for. This is the only path a third party can trigger.
    function executeHooks(MockShedCall[] calldata calls, bytes32 nonce, bytes calldata signature) external {
        if (_recover(hashToSign(calls, nonce), signature) != OWNER) revert InvalidSignature();
        if (nonces[nonce]) revert NonceReused();
        nonces[nonce] = true;
        _execute(calls);
    }

    /// @notice Execute arbitrary calls with no signature. Owner or trusted executor only.
    /// @dev This is the hole a hostile trusted executor walks through, which is why the poller pins
    ///      a factory whose sheds are only ever initialized with the factory itself.
    function trustedExecuteHooks(MockShedCall[] calldata calls) external {
        if (msg.sender != OWNER && msg.sender != trustedExecutor) revert OnlyTrustedRole();
        _execute(calls);
    }

    receive() external payable {}

    function _execute(MockShedCall[] calldata calls) private {
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = calls[i].target.call{value: calls[i].value}(calls[i].callData);
            if (!ok) revert CallReverted(i);
        }
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        return ecrecover(digest, v, r, s);
    }
}

/// @title MockCowShedFactory - stand-in for the canonical `COWShedFactory`.
/// @dev The property that matters: the only deployment path derives the shed from its owner alone
///      and initializes the trusted executor to the factory itself, which never calls
///      `trustedExecuteHooks`. So "the caller is `proxyOf(owner)`" implies "the owner authorized it".
///
///      `COMPOSABLE_COW` stands in for upstream's `implementation`: one factory deploys one flavour
///      of shed, and the flavour decides whether its sheds can settle at all. Pinning a factory in
///      the poller pins that too.
contract MockCowShedFactory {
    bytes public constant PROXY_CREATION_CODE = type(MockCowShed).creationCode;

    /// @notice The `ComposableCoW` this factory's sheds forward ERC-1271 validation to.
    ComposableCoW public immutable COMPOSABLE_COW;

    /// @dev The mutable reverse registry the poller deliberately does not trust.
    mapping(address => address) public ownerOf;

    constructor(ComposableCoW _composableCow) {
        COMPOSABLE_COW = _composableCow;
    }

    /// @notice The shed address for `owner`, whether or not it is deployed yet.
    function proxyOf(address owner) public view returns (address) {
        return _derive(_ownerSalt(owner), owner);
    }

    /// @notice Deploy `owner`'s shed if it does not exist. Idempotent and permissionless.
    function initializeProxy(address owner) public returns (address proxy) {
        proxy = proxyOf(owner);
        if (proxy.code.length == 0) {
            new MockCowShed{salt: _ownerSalt(owner)}(COMPOSABLE_COW, owner);
            // Deploy and initialize are atomic: nobody else can choose the trusted executor.
            MockCowShed(payable(proxy)).initialize(address(this));
            ownerOf[proxy] = owner;
        }
    }

    /// @notice Relay an owner-signed bundle, deploying the shed on first use. Permissionless.
    function executeHooks(MockShedCall[] calldata calls, bytes32 nonce, address owner, bytes calldata signature)
        external
        returns (address proxy)
    {
        proxy = initializeProxy(owner);
        MockCowShed(payable(proxy)).executeHooks(calls, nonce, signature);
    }

    function _ownerSalt(address owner) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)));
    }

    function _derive(bytes32 salt, address owner) internal view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(PROXY_CREATION_CODE, abi.encode(COMPOSABLE_COW, owner)));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initCodeHash)))));
    }
}

/// @title MockCowShedExecutorFactory - stand-in for cow-shed's `COWShedExecutorFactory`.
/// @dev Exists only to prove the poller rejects it. Its extra deployment path is permissionless and
///      lets the *caller* pick the trusted executor, so a shed it deploys does not imply its owner
///      authorized anything. It writes `ownerOf` all the same, which is why the poller derives with
///      `proxyOf` instead of reading that registry.
contract MockCowShedExecutorFactory is MockCowShedFactory {
    constructor(ComposableCoW _composableCow) MockCowShedFactory(_composableCow) {}

    function proxyOf(address owner, address trustedExecutor, bytes32 salt) public view returns (address) {
        return _derive(_executorSalt(owner, trustedExecutor, salt), owner);
    }

    function initializeProxy(address owner, address trustedExecutor, bytes32 salt) public returns (address proxy) {
        bytes32 create2Salt = _executorSalt(owner, trustedExecutor, salt);
        proxy = _derive(create2Salt, owner);
        if (proxy.code.length == 0) {
            new MockCowShed{salt: create2Salt}(COMPOSABLE_COW, owner);
            MockCowShed(payable(proxy)).initialize(trustedExecutor);
            ownerOf[proxy] = owner;
        }
    }

    function _executorSalt(address owner, address trustedExecutor, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, trustedExecutor, salt));
    }
}
