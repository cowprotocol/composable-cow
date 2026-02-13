// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {
    ExtensibleFallbackHandler,
    ERC1271,
    ISignatureVerifierMuxer,
    ISafeSignatureVerifier,
    Safe
} from "safe/handler/ExtensibleFallbackHandler.sol";

import {IConditionalOrder, IConditionalOrderGenerator, GPv2Order} from "./interfaces/IConditionalOrder.sol";
import {ISwapGuard} from "./interfaces/ISwapGuard.sol";
import {IValueFactory} from "./interfaces/IValueFactory.sol";
import {CoWSettlement} from "./vendored/CoWSettlement.sol";

/// @title ComposableCoW - Conditional order framework for CoW Protocol
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Enables ERC-1271 compatible wallets to create conditional orders with dual-path verification.
/// @dev Settlement path (isValidSafeSignature) is gas-optimized; polling path returns rich metadata.
contract ComposableCoW is ISafeSignatureVerifier {
    error ProofNotAuthed();
    error SingleOrderNotAuthed();
    error SwapGuardRestricted();
    error InvalidHandler();
    error InvalidFallbackHandler();
    error InterfaceNotSupported();

    struct PayloadStruct {
        bytes32[] proof;
        IConditionalOrder.ConditionalOrderParams params;
        bytes offchainInput;
    }

    struct Proof {
        uint256 location;
        bytes data;
    }

    event MerkleRootSet(address indexed owner, bytes32 root, Proof proof);
    event ConditionalOrderCreated(address indexed owner, IConditionalOrder.ConditionalOrderParams params);
    event ConditionalOrderRemoved(address indexed owner, bytes32 indexed orderHash);
    event SwapGuardSet(address indexed owner, ISwapGuard swapGuard);

    CoWSettlement public immutable settlement;
    bytes32 public immutable domainSeparator;
    mapping(address => bytes32) public roots;
    mapping(address => mapping(bytes32 => bool)) public singleOrders;
    mapping(address => ISwapGuard) public swapGuards;
    mapping(address => mapping(bytes32 => bytes32)) public cabinet;

    constructor(address _settlement) {
        settlement = CoWSettlement(_settlement);
        domainSeparator = settlement.domainSeparator();
    }

    function setRoot(bytes32 root, Proof calldata proof) public {
        roots[msg.sender] = root;
        emit MerkleRootSet(msg.sender, root, proof);
    }

    function setRootWithContext(bytes32 root, Proof calldata proof, IValueFactory factory, bytes calldata data)
        external
    {
        setRoot(root, proof);
        cabinet[msg.sender][bytes32(0)] = factory.getValue(data);
    }

    function create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch) public {
        require(address(params.handler) != address(0), InvalidHandler());
        singleOrders[msg.sender][hash(params)] = true;
        if (dispatch) {
            emit ConditionalOrderCreated(msg.sender, params);
        }
    }

    function createWithContext(
        IConditionalOrder.ConditionalOrderParams calldata params,
        IValueFactory factory,
        bytes calldata data,
        bool dispatch
    ) external {
        create(params, dispatch);
        cabinet[msg.sender][hash(params)] = factory.getValue(data);
    }

    function remove(bytes32 singleOrderHash) external {
        singleOrders[msg.sender][singleOrderHash] = false;
        cabinet[msg.sender][singleOrderHash] = bytes32(0);
        emit ConditionalOrderRemoved(msg.sender, singleOrderHash);
    }

    function setSwapGuard(ISwapGuard swapGuard) external {
        swapGuards[msg.sender] = swapGuard;
        emit SwapGuardSet(msg.sender, swapGuard);
    }

    /// @inheritdoc ISafeSignatureVerifier
    /// @dev Gas-sensitive settlement path. Calls handler.verify() directly.
    function isValidSafeSignature(
        Safe safe,
        address sender,
        bytes32 _hash,
        bytes32 _domainSeparator,
        bytes32,
        bytes calldata encodeData,
        bytes calldata payload
    ) external view override returns (bytes4 magic) {
        PayloadStruct memory _payload = abi.decode(payload, (PayloadStruct));
        bytes32 ctx = _auth(address(safe), _payload.params, _payload.proof);

        GPv2Order.Data memory order = abi.decode(encodeData, (GPv2Order.Data));

        require(_guardCheck(address(safe), ctx, _payload.params, _payload.offchainInput, order), SwapGuardRestricted());

        _payload.params.handler
            .verify(
                address(safe),
                sender,
                _hash,
                _domainSeparator,
                ctx,
                _payload.params.staticInput,
                _payload.offchainInput,
                order
            );

        return ERC1271.isValidSignature.selector;
    }

    /// @notice Poll for a tradeable order with signature and scheduling metadata
    /// @dev Returns structured result - never reverts for order conditions.
    /// @param owner The Safe/wallet that owns the order
    /// @param params The conditional order parameters
    /// @param offchainInput Dynamic input from watch-tower
    /// @param proof Merkle proof (empty for single orders)
    /// @return result Structured polling result with order (if ready) and hints
    /// @return signature EIP-1271 signature (empty if order not ready)
    function getTradeableOrderWithSignature(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof
    ) external view returns (IConditionalOrderGenerator.PollResult memory result, bytes memory signature) {
        bytes32 ctx = _auth(owner, params, proof);

        // Verify handler supports IConditionalOrderGenerator
        try IConditionalOrderGenerator(address(params.handler))
            .supportsInterface(type(IConditionalOrderGenerator).interfaceId) returns (
            bool supported
        ) {
            require(supported, InterfaceNotSupported());
        } catch {
            revert InterfaceNotSupported();
        }

        // Call poll() for structured result
        result = IConditionalOrderGenerator(address(params.handler))
            .poll(owner, msg.sender, ctx, params.staticInput, offchainInput);

        // Only build signature for SUCCESS
        if (result.code != IConditionalOrderGenerator.PollResultCode.SUCCESS) {
            return (result, "");
        }

        // Check if order has already been filled (partially or fully)
        uint256 filledAmount = _getFilledAmount(owner, result.order);
        if (filledAmount > 0) {
            // For sell orders, compare against sellAmount; for buy orders, compare against buyAmount
            uint256 totalAmount =
                result.order.kind == GPv2Order.KIND_SELL ? result.order.sellAmount : result.order.buyAmount;
            bool isFullyFilled = filledAmount >= totalAmount;
            result = IConditionalOrderGenerator.PollResult({
                code: isFullyFilled
                    ? IConditionalOrderGenerator.PollResultCode.FILLED
                    : IConditionalOrderGenerator.PollResultCode.PARTIALLY_FILLED,
                order: result.order,
                nextPollTimestamp: result.nextPollTimestamp,
                waitUntil: 0,
                reason: isFullyFilled ? "order fully filled" : "order partially filled",
                filledAmount: filledAmount
            });
            return (result, "");
        }

        // Check swap guard
        if (!_guardCheck(owner, ctx, params, offchainInput, result.order)) {
            result = IConditionalOrderGenerator.PollResult({
                code: IConditionalOrderGenerator.PollResultCode.INVALID,
                order: result.order,
                nextPollTimestamp: 0,
                waitUntil: 0,
                reason: "swap guard restricted",
                filledAmount: 0
            });
            return (result, "");
        }

        signature = _buildSignature(owner, params, offchainInput, proof, result.order);
    }

    /// @notice Quick check if an order is currently tradeable
    /// @return code The poll result code
    /// @return waitUntil For WAIT_* codes, when to retry
    function checkOrder(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof
    ) external view returns (IConditionalOrderGenerator.PollResultCode code, uint256 waitUntil) {
        bytes32 ctx = _auth(owner, params, proof);

        IConditionalOrderGenerator.PollResult memory result = IConditionalOrderGenerator(address(params.handler))
            .poll(owner, msg.sender, ctx, params.staticInput, offchainInput);

        return (result.code, result.waitUntil);
    }

    function hash(IConditionalOrder.ConditionalOrderParams memory params) public pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function _auth(address owner, IConditionalOrder.ConditionalOrderParams memory params, bytes32[] memory proof)
        internal
        view
        returns (bytes32 ctx)
    {
        if (proof.length != 0) {
            bytes32 leaf = keccak256(bytes.concat(hash(params)));
            require(MerkleProof.verify(proof, roots[owner], leaf), ProofNotAuthed());
        } else {
            ctx = hash(params);
            require(singleOrders[owner][ctx], SingleOrderNotAuthed());
        }
    }

    function _guardCheck(
        address owner,
        bytes32 ctx,
        IConditionalOrder.ConditionalOrderParams memory params,
        bytes memory offchainInput,
        GPv2Order.Data memory order
    ) internal view returns (bool) {
        ISwapGuard guard = swapGuards[owner];
        if (address(guard) != address(0)) {
            return guard.verify(order, ctx, params, offchainInput);
        }
        return true;
    }

    function _buildSignature(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof,
        GPv2Order.Data memory order
    ) internal view returns (bytes memory signature) {
        try ExtensibleFallbackHandler(owner).supportsInterface(type(ISignatureVerifierMuxer).interfaceId) returns (
            bool supported
        ) {
            require(supported, InvalidFallbackHandler());
            signature = abi.encodeWithSignature(
                "safeSignature(bytes32,bytes32,bytes,bytes)",
                domainSeparator,
                GPv2Order.TYPE_HASH,
                abi.encode(order),
                abi.encode(PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}))
            );
        } catch {
            signature = abi.encode(order, PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}));
        }
    }

    function _getFilledAmount(address owner, GPv2Order.Data memory order) internal view returns (uint256) {
        bytes memory orderUid = abi.encodePacked(GPv2Order.hash(order, domainSeparator), owner, order.validTo);
        return settlement.filledAmount(orderUid);
    }
}
