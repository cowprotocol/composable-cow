// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order, IERC20} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {IConditionalOrder} from "src/interfaces/IConditionalOrder.sol";
import {BaseConditionalOrder} from "src/BaseConditionalOrder.sol";

/// @title PollerTestHandler - test-only conditional-order generator.
/// @dev The poller treats a handler as an opaque `IConditionalOrderGenerator`, so a controllable one
///      lets the test know which order `getTradeableOrder` returns: the whole `GPv2Order.Data` is
///      carried byte-for-byte in the schedule's `staticInput`. `revertOrder` reproduces a handler
///      that refuses inside its trading window, which `pollFunds` has to let propagate.
contract PollerTestHandler is BaseConditionalOrder {
    /// @dev Mirrors `GPv2Order.Data` plus a revert flag. All-static fields, so the ABI encoding is
    ///      a plain concatenation of 32-byte words.
    struct OrderSpec {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
        bool revertOrder;
    }

    function getTradeableOrder(
        address,
        address,
        bytes32,
        bytes calldata staticInput,
        bytes calldata
    ) public pure override returns (GPv2Order.Data memory order) {
        OrderSpec memory spec = abi.decode(staticInput, (OrderSpec));
        if (spec.revertOrder) {
            revert IConditionalOrder.OrderNotValid("poller-test: not live");
        }
        order = GPv2Order.Data({
            sellToken: IERC20(spec.sellToken),
            buyToken: IERC20(spec.buyToken),
            receiver: spec.receiver,
            sellAmount: spec.sellAmount,
            buyAmount: spec.buyAmount,
            validTo: spec.validTo,
            appData: spec.appData,
            feeAmount: spec.feeAmount,
            kind: spec.kind,
            partiallyFillable: spec.partiallyFillable,
            sellTokenBalance: spec.sellTokenBalance,
            buyTokenBalance: spec.buyTokenBalance
        });
    }

    /// @dev Setup only: lets the test check its own GPv2 digest implementation against the library.
    ///      Not used inside any flow.
    function hashOrder(GPv2Order.Data calldata order, bytes32 domainSeparator) external pure returns (bytes32) {
        return GPv2Order.hash(order, domainSeparator);
    }
}

/// @title MockAggregatorV3 - test-only Chainlink-like price oracle.
/// @dev Drives the forked `StopLoss` handler, which reads two chainlink-like feeds. Setting
///      `answer` and `staleDelay` before a poll picks the branch it takes (strike reached / not
///      reached / stale / invalid price). `decimals` is fixed at deploy so the strike can be chosen
///      against a known scaling, and `updatedAt` is reported as `block.timestamp - staleDelay`
///      (clamped at 0) so freshness follows the poll block instead of drifting.
contract MockAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public staleDelay;

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function setStaleDelay(uint256 _staleDelay) external {
        staleDelay = _staleDelay;
    }

    function description() external pure returns (string memory) {
        return "MockAggregatorV3";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function _round() internal view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 updatedAt = staleDelay >= block.timestamp ? 0 : block.timestamp - staleDelay;
        return (uint80(1), answer, updatedAt, updatedAt, uint80(1));
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return _round();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return _round();
    }
}

/// @title MockERC1271Wallet - test-only ERC-1271 smart-contract wallet.
/// @dev Contract funder for `registerWithSignature` / `revokeWithSignature`. For a funder that has
///      code, `SignatureChecker` forwards the EIP-712 digest to `isValidSignature(bytes32,bytes)`
///      and wants `0x1626ba7e` back. This recovers the signer from the digest it is handed and
///      returns magic only for a fixed `owner` EOA, so a wrong digest would make it miss the owner.
contract MockERC1271Wallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant NOT_MAGIC = 0xffffffff;

    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) {
            return NOT_MAGIC;
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        address recovered = ecrecover(hash, v, r, s);
        if (recovered != address(0) && recovered == owner) {
            return MAGIC;
        }
        return NOT_MAGIC;
    }
}

/// @title PollerTestToken - test-only ERC20 with selectable transfer-result behaviour.
/// @dev Minimal on purpose (not OpenZeppelin) so the test controls how `transferFrom` reports its
///      result, which is what exercises the `GPv2SafeERC20` handling the poller relies on:
///        mode 0 - standard: returns bool true (the common case)
///        mode 1 - no return data: USDT-style, treated as success
///        mode 2 - returns bool false: `GPv2SafeERC20` must revert "GPv2: failed transferFrom"
///        mode 3 - malformed (64 bytes): must revert "GPv2: malformed transfer result"
///      A `type(uint256).max` allowance is treated as infinite (never decremented) so the test does
///      not have to track allowance decay. Balances start at zero for every account.
contract PollerTestToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint8 public immutable transferMode;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint8 _transferMode) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        transferMode = _transferMode;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        // mode 2/3 report failure without moving funds; the caller's SafeERC20 wrapper reverts.
        if (transferMode == 2) {
            return false;
        }
        if (transferMode == 3) {
            // Malformed: 64 bytes of return data.
            assembly {
                mstore(0, 1)
                mstore(32, 1)
                return(0, 64)
            }
        }

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MOCK20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);

        if (transferMode == 1) {
            // USDT-style: no return data at all.
            assembly {
                return(0, 0)
            }
        }
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "MOCK20: balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
