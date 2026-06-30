// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {ComposableCoW} from "../ComposableCoW.sol";
import {IConditionalOrder, IConditionalOrderGenerator} from "../interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller - Just-in-time funding for composable conditional orders.
/// @notice Pulls exactly the current discrete order's `sellAmount` from a funds source into the
///         order owner, immediately before that order settles. Designed to be invoked from a CoW
///         Protocol pre-hook so capital can sit in the user's EOA (or a treasury) between parts
///         instead of being locked up front for the whole order (e.g. the full notional of a
///         long-running TWAP / DCA).
/// @dev    This is the generic "ComposableCowPoller". It is not tied to any single order type.
///         The handler to poll is supplied per-schedule, and the amount / sell token /
///         validity window are all read from that handler's own `getTradeableOrder`, so the poller
///         carries no order-type-specific logic of its own.
///
///         Self-funding pre-hooks. A schedule is keyed by an `id` that is *independent of the
///         order's `appData`* (`id = scheduleId(funder, handler, owner, salt)`). This is what makes
///         `topUp` usable from the order's own appData: the conditional order's `ctx` contains its
///         `appData` hash, so a hook that referenced `ctx` (or `staticInput`, or the order digest)
///         could never be embedded in that same `appData` — it would be circular. By keying on
///         appData-independent fields and re-deriving `ctx` on-chain from the stored params, the
///         hook calldata `topUp(id)` no longer depends on `appData`, breaking the cycle. Every
///         discrete part inherits the parent order's `appData`, so each part funds itself JIT.
///
///         Security model. `topUp` is intentionally permissionless: safety comes from constraining
///         *what* a call can do, never *who* makes it:
///
///          1. The order must still be authorised: `ComposableCoW.singleOrders(owner, ctx)` must be
///             true, where `ctx` is re-derived on-chain from the stored params. `ComposableCoW.remove`
///             flips it false, which disables the poller for free.
///          2. The amount, the sell token and the validity window are all taken from the handler's
///             own `getTradeableOrder` — never from caller-supplied arguments. Outside an active
///             window `getTradeableOrder` reverts, so funds can never be pulled while no discrete
///             order is tradeable.
///          3. The destination (`owner`) is read from the schedule the funder registered, so a pull
///             can only ever move funds to the owner's own account.
///          4. Each discrete order is funded at most once, keyed by its unique order digest. This is
///             the anti-"premature execution" guard: because `getTradeableOrder` only ever yields the
///             *current* order, and a given digest is never re-funded, the *next* part's funds can
///             never be pulled before its own window opens.
///          5. The top-up is balance-capped to the current order, so repeated calls are idempotent
///             and the owner never holds more than one order's worth at a time.
///          6. The schedule `id` is namespaced by `funder`, so nobody can squat or overwrite another
///             funder's schedule.
contract ComposableCowPoller {
    /// @dev The ComposableCoW instance that authorises the order. Also the source of the domain
    ///      separator used to compute the order digest, and of `hash(params)` used to derive `ctx`.
    ComposableCoW public immutable composableCow;

    struct Schedule {
        IConditionalOrderGenerator handler; // the conditional-order handler to poll (e.g. the TWAP type)
        address funder; // source of funds (the EOA in the TWAP-for-EOA flow); the only registrant
        address owner; // order owner (cow-shed / Safe); the fixed pull destination
        bytes32 salt; // the conditional order's `salt`; with `staticInput` this rebuilds `ctx` on-chain
        bytes staticInput; // the order's `staticInput`, passed verbatim to `getTradeableOrder`
    }

    /// @dev Keyed by `id == scheduleId(funder, handler, owner, salt)`. Deliberately NOT keyed by
    ///      `ctx`: `ctx` contains the order's `appData`, so a `ctx`-keyed hook could not live inside
    ///      that same `appData`. Every field of `id` is appData-independent.
    mapping(bytes32 => Schedule) public schedules;

    /// @dev `id => digest` of the discrete order most recently funded. Each part has a distinct
    ///      digest, so this enforces "fund each discrete order at most once" and prevents the next
    ///      part from being funded before its own window opens.
    mapping(bytes32 => bytes32) public lastFunded;

    error OnlyFunder();
    error NoSchedule();
    error OrderNotLive();

    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder);
    event ScheduleRevoked(bytes32 indexed id);
    event Pulled(bytes32 indexed id, bytes32 orderDigest, uint256 amount);

    constructor(ComposableCoW _composableCow) {
        composableCow = _composableCow;
    }

    /// @notice Deterministic, appData-independent schedule key. Integrators compute this off-chain
    ///         to embed `topUp(id)` in the order's appData, and it is re-derived here on `register`.
    function scheduleId(address funder, IConditionalOrderGenerator handler, address owner, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(funder, handler, owner, salt));
    }

    /// @notice Register or update the schedule. Only the funds source itself may register, and the
    ///         `id` is namespaced by `funder`, so nobody can point a pull at someone else's funds or
    ///         squat another funder's schedule. The `id` is independent of the order's `appData`.
    function register(Schedule calldata schedule) external returns (bytes32 id) {
        if (msg.sender != schedule.funder) revert OnlyFunder();
        id = scheduleId(schedule.funder, schedule.handler, schedule.owner, schedule.salt);
        schedules[id] = schedule;
        // A re-registration starts a fresh funding history for this id.
        delete lastFunded[id];
        emit ScheduleRegistered(id, schedule.owner, schedule.funder);
    }

    /// @notice Revoke a schedule. Only the funds source may do so. A standing ERC-20 allowance
    ///         should be revoked separately to fully close the surface.
    function revoke(bytes32 id) external {
        if (msg.sender != schedules[id].funder) revert OnlyFunder();
        delete schedules[id];
        delete lastFunded[id];
        emit ScheduleRevoked(id);
    }

    /// @notice Fund the order owner with the current discrete order's `sellAmount`. Intended as a
    ///         pre-hook embedded in the order's own appData, but permissionless: the guards below
    ///         make the caller irrelevant.
    /// @dev Idempotent within an order, and a no-op once that order has been funded. Reverts
    ///      outside an active window (delegated to the handler's `getTradeableOrder`).
    function topUp(bytes32 id) external {
        Schedule memory schedule = schedules[id];
        if (schedule.funder == address(0)) revert NoSchedule();

        // Re-derive `ctx` on-chain from the stored params. `id` is appData-independent, so the hook
        // calldata `topUp(id)` does not depend on `appData` — that is what breaks the cycle that
        // would otherwise prevent embedding this call in the order's own appData.
        bytes32 ctx = composableCow.hash(
            IConditionalOrder.ConditionalOrderParams({
                handler: schedule.handler,
                salt: schedule.salt,
                staticInput: schedule.staticInput
            })
        );

        // The order must still be authorised. `remove` flips this false, disabling the poller.
        if (!composableCow.singleOrders(schedule.owner, ctx)) revert OrderNotLive();

        // Reuse the handler's own logic: this reverts outside the active window and yields the
        // exact discrete order. The amount and token come from here, so the caller controls
        // nothing that could change how much moves or in which asset.
        GPv2Order.Data memory order =
            schedule.handler.getTradeableOrder(schedule.owner, address(this), ctx, schedule.staticInput, bytes(""));

        // Fund each discrete order at most once, keyed by its unique digest.
        bytes32 digest = GPv2Order.hash(order, composableCow.domainSeparator());
        if (digest == lastFunded[id]) return;
        lastFunded[id] = digest;

        // Top up the owner to exactly the current order. The destination is fixed by the schedule.
        uint256 balance = order.sellToken.balanceOf(schedule.owner);
        if (balance < order.sellAmount) {
            uint256 deficit = order.sellAmount - balance;
            order.sellToken.transferFrom(schedule.funder, schedule.owner, deficit);
            emit Pulled(id, digest, deficit);
        }
    }
}
