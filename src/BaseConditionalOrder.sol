// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order, IERC20} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {IERC165, IConditionalOrder, IConditionalOrderGenerator} from "./interfaces/IConditionalOrder.sol";

string constant INVALID_HASH = "invalid hash";

/// @title BaseConditionalOrder - Base implementation for conditional orders
/// @author mfw78 <mfw78@nxm.rs>
/// @notice Provides dual-path support: lean verify() for settlement, rich poll() for watch-towers
abstract contract BaseConditionalOrder is IConditionalOrderGenerator {
    /// @dev Signals poll() to use order.validTo + 1 as next poll time
    uint256 internal constant POLL_AT_VALIDTO = 0;
    /// @dev Signals poll() that this is the final order, stop polling after fill
    uint256 internal constant POLL_NEVER = type(uint256).max;

    /// @inheritdoc IConditionalOrder
    function verify(
        address owner,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput,
        GPv2Order.Data calldata
    ) external view override {
        GPv2Order.Data memory order = generateOrder(owner, sender, ctx, staticInput, offchainInput);
        require(_hash == GPv2Order.hash(order, domainSeparator), IConditionalOrder.OrderNotValid(INVALID_HASH));
    }

    /// @inheritdoc IConditionalOrderGenerator
    function poll(address owner, address sender, bytes32 ctx, bytes calldata staticInput, bytes calldata offchainInput)
        external
        view
        override
        returns (IConditionalOrderGenerator.PollResult memory result)
    {
        try this.generateOrder(owner, sender, ctx, staticInput, offchainInput) returns (GPv2Order.Data memory order) {
            uint256 nextPoll = this.getNextPollTimestamp(owner, ctx, staticInput, order);
            string memory description = this.describeOrder(owner, ctx, staticInput, order);
            return IConditionalOrderGenerator.PollResult({
                code: IConditionalOrderGenerator.PollResultCode.SUCCESS,
                order: order,
                nextPollTimestamp: nextPoll,
                waitUntil: 0,
                reason: description,
                filledAmount: 0
            });
        } catch (bytes memory errorData) {
            return _decodeErrorToPollResult(errorData);
        }
    }

    /// @inheritdoc IConditionalOrderGenerator
    /// @dev Default: use order.validTo + 1. Override for multi-part orders.
    function getNextPollTimestamp(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        view
        virtual
        override
        returns (uint256)
    {
        return POLL_AT_VALIDTO;
    }

    /// @inheritdoc IConditionalOrderGenerator
    /// @dev Default: generic message. Override for better UX.
    function describeOrder(address, bytes32, bytes calldata, GPv2Order.Data memory)
        external
        view
        virtual
        override
        returns (string memory)
    {
        return "order ready";
    }

    /// @inheritdoc IConditionalOrder
    function generateOrder(
        address owner,
        address sender,
        bytes32 ctx,
        bytes calldata staticInput,
        bytes calldata offchainInput
    ) public view virtual override returns (GPv2Order.Data memory order);

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return interfaceId == type(IConditionalOrderGenerator).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Decode revert data into a PollResult
    function _decodeErrorToPollResult(bytes memory errorData)
        internal
        pure
        returns (IConditionalOrderGenerator.PollResult memory)
    {
        if (errorData.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(errorData, 32))
            }

            // OrderNotValid(string)
            if (selector == IConditionalOrder.OrderNotValid.selector) {
                string memory reason = _decodeStringError(errorData);
                return IConditionalOrderGenerator.PollResult({
                    code: IConditionalOrderGenerator.PollResultCode.INVALID,
                    order: _emptyOrder(),
                    nextPollTimestamp: 0,
                    waitUntil: 0,
                    reason: reason,
                    filledAmount: 0
                });
            }

            // PollTryNextBlock(string)
            if (selector == IConditionalOrder.PollTryNextBlock.selector) {
                string memory reason = _decodeStringError(errorData);
                return IConditionalOrderGenerator.PollResult({
                    code: IConditionalOrderGenerator.PollResultCode.TRY_NEXT_BLOCK,
                    order: _emptyOrder(),
                    nextPollTimestamp: 0,
                    waitUntil: 0,
                    reason: reason,
                    filledAmount: 0
                });
            }

            // PollTryAtTimestamp(uint256, string)
            if (selector == IConditionalOrder.PollTryAtTimestamp.selector) {
                (uint256 timestamp, string memory reason) = _decodeTimestampError(errorData);
                return IConditionalOrderGenerator.PollResult({
                    code: IConditionalOrderGenerator.PollResultCode.WAIT_TIMESTAMP,
                    order: _emptyOrder(),
                    nextPollTimestamp: 0,
                    waitUntil: timestamp,
                    reason: reason,
                    filledAmount: 0
                });
            }

            // PollTryAtBlock(uint256, string)
            if (selector == IConditionalOrder.PollTryAtBlock.selector) {
                (uint256 blockNum, string memory reason) = _decodeTimestampError(errorData);
                return IConditionalOrderGenerator.PollResult({
                    code: IConditionalOrderGenerator.PollResultCode.WAIT_BLOCK,
                    order: _emptyOrder(),
                    nextPollTimestamp: 0,
                    waitUntil: blockNum,
                    reason: reason,
                    filledAmount: 0
                });
            }
        }

        // Unknown error
        return IConditionalOrderGenerator.PollResult({
            code: IConditionalOrderGenerator.PollResultCode.INVALID,
            order: _emptyOrder(),
            nextPollTimestamp: 0,
            waitUntil: 0,
            reason: "unknown error",
            filledAmount: 0
        });
    }

    /// @dev Decode error with signature (string)
    function _decodeStringError(bytes memory errorData) internal pure returns (string memory reason) {
        if (errorData.length > 68) {
            assembly {
                errorData := add(errorData, 4)
            }
            reason = abi.decode(errorData, (string));
        } else {
            reason = "";
        }
    }

    /// @dev Decode error with signature (uint256, string)
    function _decodeTimestampError(bytes memory errorData) internal pure returns (uint256 value, string memory reason) {
        if (errorData.length > 68) {
            assembly {
                errorData := add(errorData, 4)
            }
            (value, reason) = abi.decode(errorData, (uint256, string));
        } else {
            value = 0;
            reason = "";
        }
    }

    /// @dev Create empty order for non-SUCCESS results
    function _emptyOrder() internal pure returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: IERC20(address(0)),
            buyToken: IERC20(address(0)),
            receiver: address(0),
            sellAmount: 0,
            buyAmount: 0,
            validTo: 0,
            appData: bytes32(0),
            feeAmount: 0,
            kind: bytes32(0),
            partiallyFillable: false,
            sellTokenBalance: bytes32(0),
            buyTokenBalance: bytes32(0)
        });
    }
}
