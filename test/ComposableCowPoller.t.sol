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
        poller = new ComposableCowPoller();
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
    ///      poller schedule key `id` (used for topUp/revoke).
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
        (, , bytes32 id) = _setupSchedule();

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, address(safe1), funder);

        vm.prank(funder);
        poller.revoke(id);

        // The schedule is cleared: its funder is zeroed.
        (, address scheduleFunder, , ,) = poller.schedules(id);
        assertEq(scheduleFunder, address(0), "schedule cleared");
    }

    /// @dev Only the funds source may revoke.
    function test_revoke_RevertWhen_notFunder() public {
        (, , bytes32 id) = _setupSchedule();

        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.revoke(id);
    }
}
