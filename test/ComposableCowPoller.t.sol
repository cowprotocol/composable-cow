// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {IConditionalOrder, IValueFactory, BaseComposableCoWTest} from "test/ComposableCoW.base.t.sol";

import {ComposableCoW} from "src/ComposableCoW.sol";
import {TWAP} from "src/types/twap/TWAP.sol";
import {TWAPOrder} from "src/types/twap/libraries/TWAPOrder.sol";
import {ComposableCowPoller, ICowShedFactory} from "src/types/ComposableCowPoller.sol";
import {CurrentBlockTimestampFactory} from "src/value_factories/CurrentBlockTimestampFactory.sol";
import {IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

contract CowShedFactoryMock {
    mapping(address => address) public proxyOf;

    function setProxy(address owner, address cowShed) external {
        proxyOf[owner] = cowShed;
    }
}

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
    CowShedFactoryMock cowShedFactory;
    IValueFactory currentBlockTimestampFactory;

    address funder;
    address otherFunder;

    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder);
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        twap = new TWAP(composableCow);
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
        funder = makeAddr("funder");
        otherFunder = makeAddr("other funder");
        cowShedFactory = new CowShedFactoryMock();
        cowShedFactory.setProxy(funder, address(safe1));
        cowShedFactory.setProxy(otherFunder, address(safe2));
        poller = new ComposableCowPoller(composableCow, ICowShedFactory(address(cowShedFactory)));

        // The owner (safe1) starts with no sell token: funds arrive just-in-time.
        deal(address(token0), address(safe1), 0);
    }

    function test_deployment() public {
        assertTrue(address(poller).code.length > 0, "poller deployed");
        assertEq(address(poller.COMPOSABLE_COW()), address(composableCow));
        assertEq(address(poller.COW_SHED_FACTORY()), address(cowShedFactory));
    }

    function test_constructor_RevertWhen_composableCowIsZero() public {
        vm.expectRevert(ComposableCowPoller.InvalidComposableCow.selector);
        new ComposableCowPoller(ComposableCoW(address(0)), ICowShedFactory(address(cowShedFactory)));
    }

    function test_constructor_RevertWhen_composableCowHasNoCode() public {
        vm.expectRevert(ComposableCowPoller.InvalidComposableCow.selector);
        new ComposableCowPoller(
            ComposableCoW(makeAddr("code-less ComposableCoW")), ICowShedFactory(address(cowShedFactory))
        );
    }

    function test_constructor_RevertWhen_cowShedFactoryIsZero() public {
        vm.expectRevert(ComposableCowPoller.InvalidCowShedFactory.selector);
        new ComposableCowPoller(composableCow, ICowShedFactory(address(0)));
    }

    function test_constructor_RevertWhen_cowShedFactoryHasNoCode() public {
        vm.expectRevert(ComposableCowPoller.InvalidCowShedFactory.selector);
        new ComposableCowPoller(composableCow, ICowShedFactory(makeAddr("code-less CowShed factory")));
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

        // Register as the funder EOA. Its official CowShed may also register. The schedule carries
        // the handler, funds source, destination, and order data needed to rebuild `ctx` on-chain.
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

    /// @dev An unrelated caller cannot register a schedule that draws on the funder's tokens.
    function test_register_RevertWhen_unauthorizedCaller() public {
        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
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

    /// @dev A funder's factory-derived CowShed can register and revoke its schedule.
    function test_cowShed_canRegisterAndRevoke() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 id = poller.scheduleId(schedule);

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRegistered(id, address(safe1), funder);
        vm.prank(address(safe1));
        poller.register(schedule);
        (IConditionalOrderGenerator handler,,,,) = poller.schedules(id);
        assertEq(address(handler), address(twap), "schedule registered");

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, address(safe1), funder);
        vm.prank(address(safe1));
        poller.revoke(id);
        (handler,,,,) = poller.schedules(id);
        assertEq(address(handler), address(0), "schedule revoked");
    }

    function test_register_RevertWhen_funderIsZero() public {
        address caller = makeAddr("zero funder CowShed");
        cowShedFactory.setProxy(address(0), caller);
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.funder = address(0);

        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
        vm.prank(caller);
        poller.register(schedule);
    }

    function test_register_RevertWhen_fakeCowShed() public {
        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
        vm.prank(makeAddr("fake CowShed"));
        poller.register(_schedule(SALT, abi.encode(_bundle())));
    }

    function test_register_RevertWhen_otherUsersCowShed() public {
        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
        vm.prank(address(safe2));
        poller.register(_schedule(SALT, abi.encode(_bundle())));
    }

    function test_register_RevertWhen_cowShedActsForDifferentFunder() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.funder = otherFunder;
        schedule.owner = address(safe2);

        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
        vm.prank(address(safe1));
        poller.register(schedule);
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

    /// @dev An unrelated caller cannot revoke the funder's schedule.
    function test_revoke_RevertWhen_unauthorizedCaller() public {
        (,, bytes32 id) = _setupSchedule();

        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
        poller.revoke(id);
    }

    function test_revoke_RevertWhen_otherUsersCowShed() public {
        (,, bytes32 id) = _setupSchedule();

        vm.expectRevert(ComposableCowPoller.UnauthorizedCaller.selector);
        vm.prank(address(safe2));
        poller.revoke(id);
    }

    /// @dev Funds move unconditionally: even if the owner already holds a balance (e.g. from another
    ///      concurrent order), the full part is still pulled, so orders never share funding.
    function test_pollFunds_movesFullAmountUnconditionally() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        // The owner already holds an unrelated balance (e.g. funded for another order).
        deal(address(token0), address(safe1), TWAP_PART_AMOUNT);

        poller.pollFunds(id);

        assertEq(
            token0.balanceOf(address(safe1)), TWAP_PART_AMOUNT * 2, "full part pulled on top of the existing balance"
        );
        assertEq(token0.balanceOf(funder), TWAP_PART_AMOUNT * N - TWAP_PART_AMOUNT, "a full part left the funder");
    }

    /// @dev A repeated call in the same part is a no-op, even after settlement drains the owner.
    function test_pollFunds_idempotentWithinPartAfterSettlement() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        poller.pollFunds(id);

        vm.prank(address(safe1));
        assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "part settled");
        assertEq(token0.balanceOf(address(safe1)), 0, "part settled");

        poller.pollFunds(id); // no-op: this part has already been funded

        assertEq(token0.balanceOf(address(safe1)), 0, "next part not funded early");
        assertEq(token0.balanceOf(funder), TWAP_PART_AMOUNT * N - TWAP_PART_AMOUNT, "no extra pull");
    }

    /// @dev A handler returning A, then B, then A cannot refund A, even after schedule registration.
    function test_pollFunds_doesNotRefundEarlierDigestAfterReregister() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        bytes memory staticInput = abi.encode(_bundle());
        bytes memory handlerCall = abi.encodeCall(
            IConditionalOrderGenerator.getTradeableOrder, (address(safe1), address(poller), ctx, staticInput, bytes(""))
        );
        GPv2Order.Data memory orderA =
            twap.getTradeableOrder(address(safe1), address(poller), ctx, staticInput, bytes(""));
        GPv2Order.Data memory orderB = abi.decode(abi.encode(orderA), (GPv2Order.Data));
        orderB.appData = keccak256("second valid order");

        vm.mockCall(address(twap), handlerCall, abi.encode(orderA));
        poller.pollFunds(id);
        vm.prank(address(safe1));
        assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "first order settled");

        vm.clearMockedCalls();
        vm.mockCall(address(twap), handlerCall, abi.encode(orderB));
        poller.pollFunds(id);
        vm.prank(address(safe1));
        assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "second order settled");

        vm.prank(funder);
        assertEq(
            poller.register(
                ComposableCowPoller.Schedule({
                    handler: IConditionalOrderGenerator(address(twap)),
                    funder: funder,
                    owner: address(safe1),
                    salt: SALT,
                    staticInput: staticInput
                })
            ),
            id,
            "same schedule id"
        );

        vm.clearMockedCalls();
        vm.mockCall(address(twap), handlerCall, abi.encode(orderA));
        poller.pollFunds(id);

        assertEq(token0.balanceOf(address(safe1)), 0, "first order not funded twice");
        assertEq(token0.balanceOf(funder), TWAP_PART_AMOUNT, "only two distinct orders funded");
        assertTrue(poller.funded(id, GPv2Order.hash(orderA, composableCow.domainSeparator())));
        assertTrue(poller.funded(id, GPv2Order.hash(orderB, composableCow.domainSeparator())));
    }

    /// @dev A failed ERC-20 transfer must not mark this part as funded.
    function test_pollFunds_RevertWhen_transferFromReturnsFalse() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        vm.warp(_t0(ctx));

        vm.mockCall(
            address(token0),
            abi.encodeWithSelector(token0.transferFrom.selector, funder, address(safe1), TWAP_PART_AMOUNT),
            abi.encode(false)
        );

        vm.expectRevert(bytes("GPv2: failed transferFrom"));
        poller.pollFunds(id);
    }

    /// @dev The headline flow: each part is funded JIT and the owner holds nothing in between.
    function test_pollFunds_fundsEachPartAcrossSchedule() public {
        (, bytes32 ctx, bytes32 id) = _setupSchedule();
        uint256 t0 = _t0(ctx);

        for (uint256 part = 0; part < N; part++) {
            vm.warp(t0 + part * FREQ);

            assertEq(token0.balanceOf(address(safe1)), 0, "owner empty before part");
            poller.pollFunds(id);
            assertEq(token0.balanceOf(address(safe1)), TWAP_PART_AMOUNT, "part funded");

            // Simulate the part settling: the owner's balance is consumed.
            vm.prank(address(safe1));
            assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "part settled");

            assertEq(
                token0.balanceOf(funder),
                TWAP_PART_AMOUNT * N - TWAP_PART_AMOUNT * (part + 1),
                "one part funded per window"
            );
        }
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
