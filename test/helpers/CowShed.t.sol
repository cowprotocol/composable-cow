// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

/// @dev A call a shed executes on its owner's behalf. Mirrors cow-shed's `Call` minus the
///      `allowFailure` / `isDelegateCall` flags, which nothing here exercises.
struct MockShedCall {
    address target;
    uint256 value;
    bytes callData;
}

/// @title MockCowShed - stand-in for a cow-shed proxy.
/// @dev cow-shed is not a submodule here, so these mocks reproduce only the properties
///      `ComposableCowPoller` depends on:
///
///      1. the shed lives at an address `CREATE2`-derived from its factory and its owner alone, and
///      2. it executes owner-authorized calls (`executeHooks`) or, if one is set, calls from a
///         trusted executor with no authorization at all (`trustedExecuteHooks`).
///
///      The real thing splits proxy and implementation. That split is collapsed here because the
///      poller never derives an address itself — it asks `proxyOf` and compares — so the split adds
///      no coverage. `owner` stays a constructor argument, so it is committed into the init code and
///      therefore into the derived address, exactly as in cow-shed.
contract MockCowShed {
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

    constructor(address owner) {
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
contract MockCowShedFactory {
    bytes public constant PROXY_CREATION_CODE = type(MockCowShed).creationCode;

    /// @dev The mutable reverse registry the poller deliberately does not trust.
    mapping(address => address) public ownerOf;

    /// @notice The shed address for `owner`, whether or not it is deployed yet.
    function proxyOf(address owner) public view returns (address) {
        return _derive(_ownerSalt(owner), owner);
    }

    /// @notice Deploy `owner`'s shed if it does not exist. Idempotent and permissionless.
    function initializeProxy(address owner) public returns (address proxy) {
        proxy = proxyOf(owner);
        if (proxy.code.length == 0) {
            new MockCowShed{salt: _ownerSalt(owner)}(owner);
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
        bytes32 initCodeHash = keccak256(abi.encodePacked(PROXY_CREATION_CODE, abi.encode(owner)));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, initCodeHash)))));
    }
}

/// @title MockCowShedExecutorFactory - stand-in for cow-shed's `COWShedExecutorFactory`.
/// @dev Exists only to prove the poller rejects it. Its extra deployment path is permissionless and
///      lets the *caller* pick the trusted executor, so a shed it deploys does not imply its owner
///      authorized anything. It writes `ownerOf` all the same, which is why the poller derives with
///      `proxyOf` instead of reading that registry.
contract MockCowShedExecutorFactory is MockCowShedFactory {
    function proxyOf(address owner, address trustedExecutor, bytes32 salt) public view returns (address) {
        return _derive(_executorSalt(owner, trustedExecutor, salt), owner);
    }

    function initializeProxy(address owner, address trustedExecutor, bytes32 salt) public returns (address proxy) {
        bytes32 create2Salt = _executorSalt(owner, trustedExecutor, salt);
        proxy = _derive(create2Salt, owner);
        if (proxy.code.length == 0) {
            new MockCowShed{salt: create2Salt}(owner);
            MockCowShed(payable(proxy)).initialize(trustedExecutor);
            ownerOf[proxy] = owner;
        }
    }

    function _executorSalt(address owner, address trustedExecutor, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, trustedExecutor, salt));
    }
}
