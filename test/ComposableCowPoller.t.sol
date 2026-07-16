// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {IConditionalOrder, IValueFactory, BaseComposableCoWTest} from "test/ComposableCoW.base.t.sol";

import {TWAP} from "src/types/twap/TWAP.sol";
import {TWAPOrder} from "src/types/twap/libraries/TWAPOrder.sol";
import {ComposableCowPoller} from "src/types/ComposableCowPoller.sol";
import {CurrentBlockTimestampFactory} from "src/value_factories/CurrentBlockTimestampFactory.sol";
import {IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

/// @title ComposableCowPoller unit tests
/// @notice Exercises registering a schedule for a composable TWAP created via `createWithContext`.
contract ComposableCowPollerTest is BaseComposableCoWTest {
    uint256 constant TWAP_PART_AMOUNT = 100e18;
    uint256 constant LIMIT = 1e18;
    uint256 constant N = 3;
    uint256 constant FREQ = 1 hours;
    bytes32 constant SALT = keccak256("twap");
    bytes32 constant SECOND_SALT = keccak256("second twap");

    ComposableCowPoller poller;
    IValueFactory currentBlockTimestampFactory;

    address funder;

    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        twap = new TWAP(composableCow);
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
        poller = new ComposableCowPoller(composableCow);
        funder = makeAddr("funder");

        // The owner (safe1) starts with no sell token: funds arrive just-in-time.
        deal(address(token0), address(safe1), 0);
    }

    function test_deployment() public {
        assertTrue(address(poller).code.length > 0, "poller deployed");
    }

    function _bundle() internal view returns (TWAPOrder.Data memory) {
        return TWAPOrder.Data({
            sellToken: token0,
            buyToken: token1,
            receiver: address(0), // protocol shorthand for the Safe owner
            partSellAmount: TWAP_PART_AMOUNT,
            minPartLimit: LIMIT,
            t0: 0, // resolved from the cabinet via createWithContext
            n: N,
            t: FREQ,
            span: 0, // each part is valid for its full FREQ interval
            appData: keccak256("dca.pull")
        });
    }

    /// @dev Creates a JIT-funded TWAP: order via context, the funder funds + approves the poller,
    ///      and the schedule is registered. Returns the order's cabinet key `ctx`
    ///      (`ComposableCoW.hash(params)`, used for cabinet/remove) and the appData-independent
    ///      poller schedule key `id` (used for pollFunds/revoke).
    function _setupSchedule()
        internal
        returns (IConditionalOrder.ConditionalOrderParams memory params, bytes32 ctx, bytes32 id)
    {
        params = super.createOrder(twap, SALT, abi.encode(_bundle()));
        _createWithContext(address(safe1), params, currentBlockTimestampFactory, bytes(""), false);
        ctx = composableCow.hash(params);

        // Capital lives in the funder (the EOA), which approves the poller for the full notional.
        deal(address(token0), funder, TWAP_PART_AMOUNT * N);
        vm.prank(funder);
        token0.approve(address(poller), TWAP_PART_AMOUNT * N);

        // Register the schedule (only the funder may do this). The schedule carries the handler,
        // the funds source, the destination, the order's `salt` (so the poller can rebuild `ctx`
        // on-chain) and its `staticInput`. The key is appData-independent so the funding hook can
        // live in the order's own appData.
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        id = _register(schedule);

        assertEq(id, poller.scheduleId(schedule), "id matches the off-chain derivation");
    }

    function _schedule(bytes32 salt, bytes memory staticInput)
        internal
        view
        returns (ComposableCowPoller.Schedule memory)
    {
        return ComposableCowPoller.Schedule({
            handler: IConditionalOrderGenerator(address(twap)),
            funder: funder,
            owner: address(safe1),
            salt: salt,
            staticInput: staticInput
        });
    }

    function _register(ComposableCowPoller.Schedule memory schedule) internal returns (bytes32 id) {
        vm.prank(funder);
        id = poller.register(schedule);
    }

    /// @dev The order's resolved start time `t0`, read back from the cabinet where
    ///      `createWithContext` stored it via `CurrentBlockTimestampFactory`.
    function _t0(bytes32 ctx) internal view returns (uint256) {
        return uint256(composableCow.cabinet(address(safe1), ctx));
    }

    /// @dev A registered schedule is stored under its appData-independent id.
    function test_register_storesSchedule() public {
        (,, bytes32 id) = _setupSchedule();

        (
            IConditionalOrderGenerator handler,
            address scheduleFunder,
            address owner,
            bytes32 salt,
            bytes memory staticInput
        ) = poller.schedules(id);
        assertEq(address(handler), address(twap), "handler stored");
        assertEq(scheduleFunder, funder, "funder stored");
        assertEq(owner, address(safe1), "owner stored");
        assertEq(salt, SALT, "salt stored");
        assertEq(staticInput, abi.encode(_bundle()), "static input stored");
    }

    /// @dev Distinct salts allow concurrent schedules with the same funder, handler, and owner.
    function test_register_storesSchedulesWithDifferentSalts() public {
        bytes memory staticInput = abi.encode(_bundle());
        bytes32 firstId = _register(_schedule(SALT, staticInput));
        bytes32 secondId = _register(_schedule(SECOND_SALT, staticInput));

        assertTrue(firstId != secondId, "different salts create different ids");

        (,,, bytes32 firstSalt,) = poller.schedules(firstId);
        (,,, bytes32 secondSalt,) = poller.schedules(secondId);
        assertEq(firstSalt, SALT, "first schedule remains stored");
        assertEq(secondSalt, SECOND_SALT, "second schedule stored");
    }

    /// @dev Registering the same key updates the one schedule stored under that id.
    function test_register_replacesScheduleWithSameId() public {
        bytes32 id = _register(_schedule(SALT, abi.encode(_bundle())));
        TWAPOrder.Data memory replacement = _bundle();
        replacement.appData = keccak256("updated dca pull");
        bytes memory updatedStaticInput = abi.encode(replacement);

        assertEq(_register(_schedule(SALT, updatedStaticInput)), id, "same key keeps same id");

        (,,,, bytes memory staticInput) = poller.schedules(id);
        assertEq(staticInput, updatedStaticInput, "replacement input stored");
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

    /// @dev The funder can revoke, which clears the schedule.
    function test_revoke_clearsSchedule() public {
        (,, bytes32 id) = _setupSchedule();

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, address(safe1), funder);

        vm.prank(funder);
        poller.revoke(id);

        // The whole schedule is cleared.
        (
            IConditionalOrderGenerator handler,
            address scheduleFunder,
            address owner,
            bytes32 salt,
            bytes memory staticInput
        ) = poller.schedules(id);
        assertEq(address(handler), address(0), "handler cleared");
        assertEq(scheduleFunder, address(0), "schedule cleared");
        assertEq(owner, address(0), "owner cleared");
        assertEq(salt, bytes32(0), "salt cleared");
        assertEq(staticInput, bytes(""), "static input cleared");
    }

    /// @dev Only the funds source may revoke.
    function test_revoke_RevertWhen_notFunder() public {
        (,, bytes32 id) = _setupSchedule();

        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.revoke(id);
    }

    /// @dev A single poll moves exactly the current part into the owner.
    function test_pollFunds_fundsCurrentPart() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        assertEq(
            token0.balanceOf(address(safe1)),
            0,
            "owner empty before pull"
        );

        poller.pollFunds(id);

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

    /// @dev Funds move unconditionally: even if the owner already holds a balance (e.g. from another
    ///      concurrent order), the full part is still pulled, so orders never share funding.
    function test_pollFunds_movesFullAmountUnconditionally() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        // The owner already holds an unrelated balance (e.g. funded for another order).
        deal(address(token0), address(safe1), PART);

        poller.pollFunds(id);

        assertEq(
            token0.balanceOf(address(safe1)),
            PART * 2,
            "full part pulled on top of the existing balance"
        );
        assertEq(
            token0.balanceOf(funder),
            PART * N - PART,
            "a full part left the funder"
        );
    }

    /// @dev Repeated calls for the same part are a no-op (guarded by the order digest).
    function test_pollFunds_idempotentWithinPart() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        poller.pollFunds(id);
        poller.pollFunds(id); // no-op: this part has already been funded

        assertEq(
            token0.balanceOf(address(safe1)),
            PART,
            "still exactly one part"
        );
        assertEq(token0.balanceOf(funder), PART * N - PART, "no extra pull");
    }

    /// @dev A failed ERC-20 transfer must not mark this part as funded.
    function test_pollFunds_RevertWhen_transferFromReturnsFalse() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        vm.mockCall(
            address(token0),
            abi.encodeWithSelector(
                token0.transferFrom.selector,
                funder,
                address(safe1),
                PART
            ),
            abi.encode(false)
        );

        vm.expectRevert(bytes("GPv2: failed transferFrom"));
        poller.pollFunds(id);

        assertEq(poller.lastFunded(id), bytes32(0), "failed pull is not recorded");
    }

    /// @dev The headline flow: each part is funded JIT and the owner holds nothing in between.
    function test_pollFunds_fundsEachPartAcrossSchedule() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        uint256 t0 = _t0(ctx);

        for (uint256 part = 0; part < N; part++) {
            vm.warp(t0 + part * FREQ);

            assertEq(
                token0.balanceOf(address(safe1)),
                0,
                "owner empty before part"
            );
            poller.pollFunds(id);
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
    function test_pollFunds_cannotFundFuturePartEarly() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx)); // part 0 window

        poller.pollFunds(id);
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
        poller.pollFunds(id);

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
    function test_pollFunds_RevertWhen_scheduleEnded() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx) + N * FREQ);

        vm.expectRevert(); // IConditionalOrder.OrderNotValid(...) from the handler
        poller.pollFunds(id);
    }

    /// @dev An unregistered schedule cannot be polled.
    function test_pollFunds_RevertWhen_noSchedule() public {
        vm.expectRevert(ComposableCowPoller.NoSchedule.selector);
        poller.pollFunds(keccak256("unknown"));
    }

    /// @dev Cancelling the order flips `singleOrders` false, which disables the poller for free.
    function test_remove_killsPoller() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        vm.prank(address(safe1));
        composableCow.remove(ctx);

        vm.expectRevert(ComposableCowPoller.OrderNotLive.selector);
        poller.pollFunds(id);
    }
}
