// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IERC20, GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {IConditionalOrder, IValueFactory, ComposableCoW, BaseComposableCoWTest} from "./ComposableCoW.base.t.sol";

import {TWAP} from "../src/types/twap/TWAP.sol";
import {TWAPOrder} from "../src/types/twap/libraries/TWAPOrder.sol";
import {ComposableCowPoller} from "../src/types/ComposableCowPoller.sol";
import {CurrentBlockTimestampFactory} from "../src/value_factories/CurrentBlockTimestampFactory.sol";
import {IConditionalOrderGenerator} from "../src/interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller unit tests
/// @notice Exercises just-in-time funding of a composable TWAP created via `createWithContext`.
///         The poller is the only thing under test here, so instead of running a full settlement
///         we simulate a part being filled by draining the owner's balance directly.
contract ComposableCowPollerTest is BaseComposableCoWTest {
    uint256 constant PART = 100e18;
    uint256 constant LIMIT = 1e18;
    uint256 constant N = 3;
    uint256 constant FREQ = 1 hours;
    bytes32 constant SALT = keccak256("twap");

    ComposableCowPoller poller;
    IValueFactory currentBlockTimestampFactory;

    address funder;

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        twap = new TWAP(composableCow);
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
        poller = new ComposableCowPoller(composableCow);
        funder = makeAddr("funder");

        // The owner (safe1) starts with no sell token: funds arrive just-in-time.
        deal(address(token0), address(safe1), 0);
    }

    function _bundle() internal view returns (TWAPOrder.Data memory) {
        return
            TWAPOrder.Data({
                sellToken: token0,
                buyToken: token1,
                receiver: address(0), // the owner itself
                partSellAmount: PART,
                minPartLimit: LIMIT,
                t0: 0, // resolved from the cabinet via createWithContext
                n: N,
                t: FREQ,
                span: 0, // valid for the whole epoch
                appData: keccak256("dca.pull")
            });
    }

    /// @dev Creates a JIT-funded TWAP: order via context, the funder funds + approves the poller,
    ///      and the schedule is registered. Returns the order's cabinet key `ctx`
    ///      (`ComposableCoW.hash(params)`, used for cabinet/remove) and the appData-independent
    ///      poller schedule key `id` (used for topUp/revoke).
    function _setupSchedule()
        internal
        returns (
            IConditionalOrder.ConditionalOrderParams memory params,
            bytes32 ctx,
            bytes32 id
        )
    {
        params = super.createOrder(twap, SALT, abi.encode(_bundle()));
        _createWithContext(
            address(safe1),
            params,
            currentBlockTimestampFactory,
            bytes(""),
            false
        );
        ctx = composableCow.hash(params);

        // Capital lives in the funder (the EOA), which approves the poller for the full notional.
        deal(address(token0), funder, PART * N);
        vm.prank(funder);
        token0.approve(address(poller), PART * N);

        // Register the schedule (only the funder may do this). The schedule carries the handler,
        // the funds source, the destination, the order's `salt` (so the poller can rebuild `ctx`
        // on-chain) and its `staticInput`. The key is appData-independent so `topUp(id)` can live
        // in the order's own appData.
        vm.prank(funder);
        id = poller.register(
            ComposableCowPoller.Schedule({
                handler: IConditionalOrderGenerator(address(twap)),
                funder: funder,
                owner: address(safe1),
                salt: SALT,
                staticInput: abi.encode(_bundle())
            })
        );

        assertEq(
            id,
            poller.scheduleId(
                funder,
                IConditionalOrderGenerator(address(twap)),
                address(safe1),
                SALT
            ),
            "id matches the off-chain derivation"
        );
    }

    function _t0(bytes32 ctx) internal view returns (uint256) {
        return uint256(composableCow.cabinet(address(safe1), ctx));
    }

    /// @dev A single top-up funds the owner with exactly the current part.
    function test_topUp_fundsCurrentPart() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        assertEq(
            token0.balanceOf(address(safe1)),
            0,
            "owner empty before pull"
        );

        poller.topUp(id);

        assertEq(
            token0.balanceOf(address(safe1)),
            PART,
            "owner funded with exactly one part"
        );
        assertEq(
            token0.balanceOf(funder),
            PART * N - PART,
            "exactly one part left the funder"
        );
    }

    /// @dev Repeated calls within a part are idempotent (balance-capped to one part).
    function test_topUp_idempotentWithinPart() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        poller.topUp(id);
        poller.topUp(id); // no-op: this part has already been funded

        assertEq(
            token0.balanceOf(address(safe1)),
            PART,
            "still exactly one part"
        );
        assertEq(token0.balanceOf(funder), PART * N - PART, "no extra pull");
    }

    /// @dev The headline flow: each part is funded JIT and the owner holds nothing in between.
    function test_topUp_fundsEachPartAcrossSchedule() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        uint256 t0 = _t0(ctx);

        for (uint256 part = 0; part < N; part++) {
            vm.warp(t0 + part * FREQ);

            assertEq(
                token0.balanceOf(address(safe1)),
                0,
                "owner empty before part"
            );
            poller.topUp(id);
            assertEq(token0.balanceOf(address(safe1)), PART, "part funded");

            // Simulate the part settling: the owner's balance is consumed.
            vm.prank(address(safe1));
            token0.transfer(bob.addr, PART);

            assertEq(
                token0.balanceOf(funder),
                PART * N - PART * (part + 1),
                "one part funded per window"
            );
        }
    }

    /// @dev The anti-premature-execution guard: once a part is funded, the *next* part's funds
    ///      cannot be pulled until time advances into its window — even after the part settles and
    ///      drains the owner. Without the per-order guard, the drained owner would be refilled
    ///      immediately and that balance would be sold as the next part, a full interval early.
    function test_topUp_cannotFundFuturePartEarly() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx)); // part 0 window

        poller.topUp(id);
        assertEq(token0.balanceOf(address(safe1)), PART, "part 0 funded");

        // Simulate the part settling: the owner's balance is consumed.
        vm.prank(address(safe1));
        token0.transfer(bob.addr, PART);
        assertEq(
            token0.balanceOf(address(safe1)),
            0,
            "owner drained by the fill"
        );

        // Still inside part 0's window: a fresh pull must NOT refill.
        poller.topUp(id);

        assertEq(
            token0.balanceOf(address(safe1)),
            0,
            "next part not funded early"
        );
        assertEq(
            token0.balanceOf(funder),
            PART * N - PART,
            "exactly one part ever left the funder"
        );
    }

    /// @dev The pull is bounded to the schedule window: after it ends, `getTradeableOrder` reverts.
    function test_topUp_RevertWhen_scheduleEnded() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx) + N * FREQ);

        vm.expectRevert(); // IConditionalOrder.OrderNotValid(...) from the handler
        poller.topUp(id);
    }

    /// @dev An unregistered schedule cannot be topped up.
    function test_topUp_RevertWhen_noSchedule() public {
        vm.expectRevert(ComposableCowPoller.NoSchedule.selector);
        poller.topUp(keccak256("unknown"));
    }

    /// @dev Cancelling the order flips `singleOrders` false, which disables the poller for free.
    function test_remove_killsPoller() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        vm.prank(address(safe1));
        composableCow.remove(ctx);

        vm.expectRevert(ComposableCowPoller.OrderNotLive.selector);
        poller.topUp(id);
    }

    /// @dev Only the funds source may register a schedule that draws on its own funds.
    function test_register_RevertWhen_notFunder() public {
        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.register(
            ComposableCowPoller.Schedule({
                handler: IConditionalOrderGenerator(address(twap)),
                funder: funder, // attacker points at someone else's funds
                owner: address(safe1),
                salt: SALT,
                staticInput: abi.encode(_bundle())
            })
        );
    }

    /// @dev Only the funder may revoke, and doing so clears the schedule.
    function test_revoke_clearsSchedule() public {
        (, , bytes32 id) = _setupSchedule();

        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.revoke(id);

        vm.prank(funder);
        poller.revoke(id);

        vm.expectRevert(ComposableCowPoller.NoSchedule.selector);
        poller.topUp(id);
    }
}
