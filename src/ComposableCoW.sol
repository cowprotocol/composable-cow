// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "safe/handler/ExtensibleFallbackHandler.sol";

import "./interfaces/IConditionalOrder.sol";
import "./interfaces/ISwapGuard.sol";
import "./interfaces/IValueFactory.sol";
import "./vendored/CoWSettlement.sol";

/**
 * @title ComposableCoW - A contract that allows users to create multiple conditional orders
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @dev Designed to be used with Safe + ExtensibleFallbackHandler
 */
contract ComposableCoW is ISafeSignatureVerifier {
    // --- errors
    error ProofNotAuthed();
    error SingleOrderNotAuthed();
    error SwapGuardRestricted();
    error InvalidHandler();
    error InvalidFallbackHandler();
    error InterfaceNotSupported();

    // --- types

    // A struct to encapsulate order parameters / offchain input
    struct PayloadStruct {
        bytes32[] proof;
        IConditionalOrder.ConditionalOrderParams params;
        bytes offchainInput;
    }

    // A struct representing where to find the proofs
    struct Proof {
        uint256 location;
        bytes data;
    }

    // --- events

    // An event emitted when a user sets their merkle root
    event MerkleRootSet(address indexed owner, bytes32 root, Proof proof);
    event ConditionalOrderCreated(address indexed owner, IConditionalOrder.ConditionalOrderParams params);
    event SwapGuardSet(address indexed owner, ISwapGuard swapGuard);

    // --- state
    // Domain separator is only used for generating signatures
    bytes32 public immutable domainSeparator;
    /// @dev Mapping of owner's merkle roots
    mapping(address => bytes32) public roots;
    /// @dev Mapping of owner's single orders
    mapping(address => mapping(bytes32 => bool)) public singleOrders;
    // @dev Mapping of owner's swap guard
    mapping(address => ISwapGuard) public swapGuards;
    // @dev Mapping of owner's on-chain storage slots
    mapping(address => mapping(bytes32 => bytes32)) public cabinet;

    // --- constructor

    /**
     * @param _settlement The GPv2 settlement contract
     */
    constructor(address _settlement) {
        domainSeparator = CoWSettlement(_settlement).domainSeparator();
    }

    // --- setters

    /**
     * Set the merkle root of the user's conditional orders
     * @notice Set the merkle root of the user's conditional orders
     * @param root The merkle root of the user's conditional orders
     * @param proof Where to find the proofs
     */
    function setRoot(bytes32 root, Proof calldata proof) public {
        roots[msg.sender] = root;
        emit MerkleRootSet(msg.sender, root, proof);
    }

    /**
     * Set the merkle root of the user's conditional orders and store a value from on-chain in the cabinet
     * @param root The merkle root of the user's conditional orders
     * @param proof Where to find the proofs
     * @param factory A factory from which to get a value to store in the cabinet related to the merkle root
     * @param data Implementation specific off-chain data
     */
    function setRootWithContext(bytes32 root, Proof calldata proof, IValueFactory factory, bytes calldata data)
        external
    {
        setRoot(root, proof);

        // Default to the zero slot for a merkle root as this is the most common use case
        // and should save gas on calldata when reading the cabinet.

        // Set the cabinet slot
        cabinet[msg.sender][bytes32(0)] = factory.getValue(data);
    }

    /**
     * Authorise a single conditional order
     * @param params The parameters of the conditional order
     * @param dispatch Whether to dispatch the `ConditionalOrderCreated` event
     */
    function create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch) public {
        if (!(address(params.handler) != address(0))) {
            revert InvalidHandler();
        }

        singleOrders[msg.sender][hash(params)] = true;
        if (dispatch) {
            emit ConditionalOrderCreated(msg.sender, params);
        }
    }

    /**
     * Authorise a single conditional order and store a value from on-chain in the cabinet
     * @param params The parameters of the conditional order
     * @param factory A factory from which to get a value to store in the cabinet
     * @param data Implementation specific off-chain data
     * @param dispatch Whether to dispatch the `ConditionalOrderCreated` event
     */
    function createWithContext(
        IConditionalOrder.ConditionalOrderParams calldata params,
        IValueFactory factory,
        bytes calldata data,
        bool dispatch
    ) external {
        create(params, dispatch);

        // When setting the slot, an opinionated direction is taken to tie the return value of
        // the slot to the conditional order, such that there is a guarantee or data integrity

        // Set the cabinet slot
        cabinet[msg.sender][hash(params)] = factory.getValue(data);
    }

    /**
     * Remove the authorisation of a single conditional order
     * @param singleOrderHash The hash of the single conditional order to remove
     */
    function remove(bytes32 singleOrderHash) external {
        singleOrders[msg.sender][singleOrderHash] = false;
        cabinet[msg.sender][singleOrderHash] = bytes32(0);
    }

    /**
     * Set the swap guard of the user's conditional orders
     * @param swapGuard The address of the swap guard
     */
    function setSwapGuard(ISwapGuard swapGuard) external {
        swapGuards[msg.sender] = swapGuard;
        emit SwapGuardSet(msg.sender, swapGuard);
    }

    // --- ISafeSignatureVerifier

    /**
     * @inheritdoc ISafeSignatureVerifier
     * @dev This function does not make use of the `typeHash` parameter as CoW Protocol does not
     *      have more than one type.
     * @param encodeData Is the abi encoded `GPv2Order.Data`
     * @param payload Is the abi encoded `PayloadStruct`
     */
    function isValidSafeSignature(
        Safe safe,
        address sender,
        bytes32 _hash,
        bytes32 _domainSeparator,
        bytes32, // typeHash
        bytes calldata encodeData,
        bytes calldata payload
    ) external view override returns (bytes4 magic) {
        // First decode the payload
        PayloadStruct memory _payload = abi.decode(payload, (PayloadStruct));

        // Check if the order is authorised
        bytes32 ctx = _auth(address(safe), _payload.params, _payload.proof);

        // It's an authorised order, validate it.
        GPv2Order.Data memory order = abi.decode(encodeData, (GPv2Order.Data));

        // Check with the swap guard if the order is restricted or not
        if (!(_guardCheck(address(safe), ctx, _payload.params, _payload.offchainInput, order))) {
            revert SwapGuardRestricted();
        }

        // Proof is valid, guard (if any) is valid, now check the handler
        _payload.params.handler.verify(
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

    // --- getters

    /**
     * Get the `GPv2Order.Data` and signature for submitting to CoW Protocol API
     * @param owner of the order
     * @param params `ConditionalOrderParams` for the order
     * @param offchainInput any dynamic off-chain input for generating the discrete order
     * @param proof if using merkle-roots that H(handler || salt || staticInput) is in the merkle tree
     * @return order discrete order for submitting to CoW Protocol API
     * @return signature for submitting to CoW Protocol API
     */
    function getTradeableOrderWithSignature(
        address owner,
        IConditionalOrder.ConditionalOrderParams calldata params,
        bytes calldata offchainInput,
        bytes32[] calldata proof
    ) external view returns (GPv2Order.Data memory order, bytes memory signature) {
        // Check if the order is authorised and in doing so, get the context
        bytes32 ctx = _auth(owner, params, proof);

        // Make sure the handler supports `IConditionalOrderGenerator`
        try IConditionalOrderGenerator(address(params.handler)).supportsInterface(
            type(IConditionalOrderGenerator).interfaceId
        ) returns (bool supported) {
            if (!supported) {
                revert InterfaceNotSupported();
            }
        } catch {
            revert InterfaceNotSupported();
        }

        order = IConditionalOrderGenerator(address(params.handler)).getTradeableOrder(
            owner, msg.sender, ctx, params.staticInput, offchainInput
        );

        // Check with the swap guard if the order is restricted or not
        if (!(_guardCheck(owner, ctx, params, offchainInput, order))) {
            revert SwapGuardRestricted();
        }

        try ExtensibleFallbackHandler(owner).supportsInterface(type(ISignatureVerifierMuxer).interfaceId) returns (
            bool supported
        ) {
            if (!supported) {
                revert InvalidFallbackHandler();
            }
            signature = abi.encodeWithSignature(
                "safeSignature(bytes32,bytes32,bytes,bytes)",
                domainSeparator,
                GPv2Order.TYPE_HASH,
                abi.encode(order),
                abi.encode(PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}))
            );
        } catch {
            // Assume that this is the EIP-1271 Forwarder (which does not have a `NAME` function)
            // The default signature is the abi.encode of the tuple (order, payload)
            signature = abi.encode(order, PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}));
        }
    }

    // --- helper viewer functions

    /**
     * Return the hash of the conditional order parameters
     * @param params `ConditionalOrderParams` for the order
     * @return hash of the conditional order parameters
     */
    function hash(IConditionalOrder.ConditionalOrderParams memory params) public pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    // --- internal functions

    /**
     * Check if the order has been authorised by the owner
     * @dev If `proof.length == 0`, then we use the single order auth
     * @param owner of the order whose authorisation is being checked
     * @param params that uniquely identify the order
     * @param proof to assert that H(params) is in the merkle tree (optional)
     */
    function _auth(address owner, IConditionalOrder.ConditionalOrderParams memory params, bytes32[] memory proof)
        internal
        view
        returns (bytes32 ctx)
    {
        if (proof.length != 0) {
            /// @dev Computing proof using leaf double hashing
            bytes32 leaf = keccak256(bytes.concat(hash(params)));

            // Check if the proof is valid
            if (!MerkleProof.verify(proof, roots[owner], leaf)) {
                revert ProofNotAuthed();
            }
        } else {
            // Check if the order is authorised
            ctx = hash(params);
            if (!singleOrders[owner][ctx]) {
                revert SingleOrderNotAuthed();
            }
        }
    }

    /**
     * Check the swap guard if the order is restricted or not
     * @param owner who's swap guard to check
     * @param ctx of the order (bytes32(0) if a merkle tree is used, otherwise H(params))
     * @param params that uniquely identify the order
     * @param offchainInput that has been proposed by `sender`
     * @param order GPv2Order.Data that has been proposed by `sender`
     */
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
}
