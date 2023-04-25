// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "safe/handler/ExtensibleFallbackHandler.sol";

import "./interfaces/IConditionalOrder.sol";
import "./interfaces/ISwapGuard.sol";
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
    function setRoot(bytes32 root, Proof calldata proof) external {
        roots[msg.sender] = root;
        emit MerkleRootSet(msg.sender, root, proof);
    }

    /**
     * Authorise a single conditional order
     * @param params The parameters of the conditional order
     * @param dispatch Whether to dispatch the `ConditionalOrderCreated` event
     */
    function create(IConditionalOrder.ConditionalOrderParams calldata params, bool dispatch) external {
        singleOrders[msg.sender][keccak256(abi.encode(params))] = true;
        if (dispatch) {
            emit ConditionalOrderCreated(msg.sender, params);
        }
    }

    /**
     * Remove the authorisation of a single conditional order
     * @param singleOrderHash The hash of the single conditional order to remove
     */
    function remove(bytes32 singleOrderHash) external {
        singleOrders[msg.sender][singleOrderHash] = false;
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
        _auth(address(safe), _payload.params, _payload.proof);

        // It's an authorised order, validate it.
        GPv2Order.Data memory order = abi.decode(encodeData, (GPv2Order.Data));

        // Check with the swap guard if the order is restricted or not
        if (!(_guardCheck(address(safe), _payload.params, _payload.offchainInput, order))) {
            revert SwapGuardRestricted();
        }

        // Proof is valid, guard (if any)_ is valid, now check the handler
        _payload.params.handler.verify(
            address(safe),
            sender,
            _hash,
            _domainSeparator,
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
        // Check if the order is authorised
        _auth(owner, params, proof);

        // Make sure the handler supports `IConditionalOrderGenerator`
        require(
            IConditionalOrderGenerator(address(params.handler)).supportsInterface(
                type(IConditionalOrderGenerator).interfaceId
            ),
            "Handler does not support IConditionalOrderGenerator"
        );
        order = IConditionalOrderGenerator(address(params.handler)).getTradeableOrder(
            owner, msg.sender, params.staticInput, offchainInput
        );

        // Check with the swap guard if the order is restricted or not
        if (!(_guardCheck(owner, params, offchainInput, order))) {
            revert SwapGuardRestricted();
        }

        try ExtensibleFallbackHandler(owner).NAME() returns (string memory name) {
            // Confirm that the name is "Extensible Fallback Handler"
            require(
                keccak256(abi.encodePacked(name)) == keccak256(abi.encodePacked("Extensible Fallback Handler")),
                "Invalid fallback handler"
            );
            signature = abi.encodeWithSignature(
                "safeSignature(bytes32,bytes32,bytes,bytes)",
                domainSeparator,
                GPv2Order.TYPE_HASH,
                abi.encode(order),
                abi.encode(PayloadStruct({params: params, offchainInput: offchainInput, proof: proof}))
            );
        } catch {
            // TODO: Insert alternative formatting for EIP-1271 Forwarder
        }
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
    {
        /// @dev Computing proof using leaf double hashing
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(params))));
        if (!(proof.length == 0 || MerkleProof.verify(proof, roots[owner], leaf))) {
            revert ProofNotAuthed();
        }

        if (!(proof.length != 0 || singleOrders[owner][keccak256(abi.encode(params))])) {
            revert SingleOrderNotAuthed();
        }
    }

    /**
     * Check the swap guard if the order is restricted or not
     * @param owner who's swap guard to check
     * @param params that uniquely identify the order
     * @param offchainInput that has been proposed by `sender`
     * @param order GPv2Order.Data that has been proposed by `sender`
     */
    function _guardCheck(
        address owner,
        IConditionalOrder.ConditionalOrderParams memory params,
        bytes memory offchainInput,
        GPv2Order.Data memory order
    ) internal view returns (bool) {
        ISwapGuard guard = swapGuards[owner];
        if (address(guard) != address(0)) {
            return guard.verify(order, params, offchainInput);
        }
        return true;
    }
}
