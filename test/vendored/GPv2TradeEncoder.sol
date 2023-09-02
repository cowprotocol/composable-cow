// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {GPv2Order} from "cowprotocol/libraries/GPv2Order.sol";
import {GPv2Signing} from "cowprotocol/mixins/GPv2Signing.sol";

/// @title Gnosis Protocol v2 Trade Library.
/// @author mfw78 <mfw78@rndlabs.xyz>
/// @dev This library provides functions for encoding trade flags
/// Encoding methodology is adapted from upstream at
/* solhint-disable-next-line max-line-length */
/// https://github.com/cowprotocol/contracts/blob/d043b0bfac7a09463c74dfe1613d0612744ed91c/src/contracts/libraries/GPv2Trade.sol
library GPv2TradeEncoder {
    using GPv2Order for GPv2Order.Data;

    // uint256 constant FLAG_ORDER_KIND_SELL = 0x00;
    uint256 constant FLAG_ORDER_KIND_BUY = 0x01;

    // uint256 constant FLAG_FILL_FOK = 0x00;
    uint256 constant FLAG_FILL_PARTIAL = 0x02;

    // uint256 constant FLAG_SELL_TOKEN_ERC20_TOKEN_BALANCE = 0x00;
    uint256 constant FLAG_SELL_TOKEN_BALANCER_EXTERNAL = 0x08;
    uint256 constant FLAG_SELL_TOKEN_BALANCER_INTERNAL = 0x0c;

    // uint256 constant FLAG_BUY_TOKEN_ERC20_TOKEN_BALANCE = 0x00;
    uint256 constant FLAG_BUY_TOKEN_BALANCER_INTERNAL = 0x10;

    // uint256 constant FLAG_SIGNATURE_SCHEME_EIP712 = 0x00;
    uint256 constant FLAG_SIGNATURE_SCHEME_ETHSIGN = 0x20;
    uint256 constant FLAG_SIGNATURE_SCHEME_EIP1271 = 0x40;
    uint256 constant FLAG_SIGNATURE_SCHEME_PRESIGN = 0x60;

    /// @dev Decodes trade flags.
    ///
    /// Trade flags are used to tightly encode information on how to decode
    /// an order. Examples that directly affect the structure of an order are
    /// the kind of order (either a sell or a buy order) as well as whether the
    /// order is partially fillable or if it is a "fill-or-kill" order. It also
    /// encodes the signature scheme used to validate the order. As the most
    /// likely values are fill-or-kill sell orders by an externally owned
    /// account, the flags are chosen such that `0x00` represents this kind of
    /// order. The flags byte uses the following format:
    ///
    /// ```
    /// bit | 31 ...   | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
    /// ----+----------+-------+---+-------+---+---+
    ///     | reserved | *   * | * | *   * | * | * |
    ///                  |   |   |   |   |   |   |
    ///                  |   |   |   |   |   |   +---- order kind bit, 0 for a sell order
    ///                  |   |   |   |   |   |         and 1 for a buy order
    ///                  |   |   |   |   |   |
    ///                  |   |   |   |   |   +-------- order fill bit, 0 for fill-or-kill
    ///                  |   |   |   |   |             and 1 for a partially fillable order
    ///                  |   |   |   |   |
    ///                  |   |   |   +---+------------ use internal sell token balance bit:
    ///                  |   |   |                     0x: ERC20 token balance
    ///                  |   |   |                     10: external Balancer Vault balance
    ///                  |   |   |                     11: internal Balancer Vault balance
    ///                  |   |   |
    ///                  |   |   +-------------------- use buy token balance bit
    ///                  |   |                         0: ERC20 token balance
    ///                  |   |                         1: internal Balancer Vault balance
    ///                  |   |
    ///                  +---+------------------------ signature scheme bits:
    ///                                                00: EIP-712
    ///                                                01: eth_sign
    ///                                                10: EIP-1271
    ///                                                11: pre_sign
    /// ```
    function encodeFlags(GPv2Order.Data memory order, GPv2Signing.Scheme signingScheme)
        internal
        pure
        returns (uint256 flags)
    {
        // set the zero index bit if the order is a buy order
        if (order.kind == GPv2Order.KIND_BUY) {
            flags |= FLAG_ORDER_KIND_BUY;
        }

        // set the first index bit if the order is partially fillable
        if (order.partiallyFillable) {
            flags |= FLAG_FILL_PARTIAL;
        }

        // set the second and third index bit based on the sell token liquidity
        if (order.sellTokenBalance == GPv2Order.BALANCE_EXTERNAL) {
            flags |= FLAG_SELL_TOKEN_BALANCER_EXTERNAL;
        } else if (order.sellTokenBalance == GPv2Order.BALANCE_INTERNAL) {
            flags |= FLAG_SELL_TOKEN_BALANCER_INTERNAL;
        }

        // set the fourth index bit based on the buy token liquidity
        if (order.buyTokenBalance == GPv2Order.BALANCE_INTERNAL) {
            flags |= FLAG_BUY_TOKEN_BALANCER_INTERNAL;
        }

        // set the fifth and sixth index bit based on the signature scheme
        if (signingScheme == GPv2Signing.Scheme.EthSign) {
            flags |= FLAG_SIGNATURE_SCHEME_ETHSIGN;
        } else if (signingScheme == GPv2Signing.Scheme.Eip1271) {
            flags |= FLAG_SIGNATURE_SCHEME_EIP1271;
        } else if (signingScheme == GPv2Signing.Scheme.PreSign) {
            flags |= FLAG_SIGNATURE_SCHEME_PRESIGN;
        }

        return flags;
    }
}
