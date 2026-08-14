// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";

import {IConditionalOrder, IValueFactory, BaseComposableCoWTest} from "test/ComposableCoW.base.t.sol";
import {
    MockCowShed,
    MockCowShedExecutorFactory,
    MockCowShedFactory,
    MockShedCall
} from "test/helpers/CowShed.t.sol";

import {TWAP} from "src/types/twap/TWAP.sol";
import {TWAPOrder} from "src/types/twap/libraries/TWAPOrder.sol";
import {ComposableCowPoller, ICowShedFactory} from "src/types/ComposableCowPoller.sol";
import {CurrentBlockTimestampFactory} from "src/value_factories/CurrentBlockTimestampFactory.sol";
import {IConditionalOrderGenerator} from "src/interfaces/IConditionalOrder.sol";

contract TestPollerERC1271Signer {
    bytes32 private validDigest;
    bytes32 private validSignatureHash;

    function allow(bytes32 digest, bytes calldata signature) external {
        validDigest = digest;
        validSignatureHash = keccak256(signature);
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return digest == validDigest && keccak256(signature) == validSignatureHash
            ? this.isValidSignature.selector
            : bytes4(0xffffffff);
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
    IValueFactory currentBlockTimestampFactory;
    MockCowShedFactory shedFactory;

    address funder;
    uint256 funderPrivateKey;
    /// @dev `funder`'s shed, the only address allowed on the `FromShed` paths.
    address funderShed;

    event ScheduleRegistered(
        bytes32 indexed id, address indexed owner, address indexed funder, uint96 authEpoch, bytes32 paramsHash
    );
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);
    event Pulled(bytes32 indexed id, bytes32 indexed orderDigest, uint256 amount);

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        twap = new TWAP(composableCow);
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
        shedFactory = new MockCowShedFactory();
        poller = new ComposableCowPoller(composableCow, ICowShedFactory(address(shedFactory)));
        (funder, funderPrivateKey) = makeAddrAndKey("funder");
        funderShed = shedFactory.proxyOf(funder);
        vm.label(funderShed, "funderShed");

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
    ///      and the schedule is registered. Returns the order's `paramsHash`
    ///      (`ComposableCoW.hash(params)`, the cabinet/remove key) and the appData-independent
    ///      poller schedule key `id` (used for pollFunds/revoke).
    function _setupSchedule()
        internal
        returns (IConditionalOrder.ConditionalOrderParams memory params, bytes32 paramsHash, bytes32 id)
    {
        params = super.createOrder(twap, SALT, abi.encode(_bundle()));
        _createWithContext(address(safe1), params, currentBlockTimestampFactory, bytes(""), false);
        paramsHash = composableCow.hash(params);

        // Capital lives in the funder (the EOA), which approves the poller for the full notional.
        deal(address(token0), funder, TWAP_PART_AMOUNT * N);
        vm.prank(funder);
        token0.approve(address(poller), TWAP_PART_AMOUNT * N);

        // Register the schedule (only the funder may do this). The schedule carries the handler,
        // the funds source, the destination, the order's `salt` (so the poller can rebuild the
        // hash on-chain) and its `staticInput`. The key is appData-independent so the funding hook
        // can live in the order's own appData.
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
            authEpoch: 0,
            funder: funder,
            owner: address(safe1),
            salt: salt,
            staticInput: staticInput
        });
    }

    function _expectedParamsHash(bytes32 salt, bytes memory staticInput) internal view returns (bytes32) {
        return composableCow.hash(
            IConditionalOrder.ConditionalOrderParams({
                handler: IConditionalOrder(address(twap)),
                salt: salt,
                staticInput: staticInput
            })
        );
    }

    function _register(ComposableCowPoller.Schedule memory schedule) internal returns (bytes32 id) {
        vm.prank(schedule.funder);
        id = poller.register(schedule);
    }

    function _registerDigest(ComposableCowPoller.Schedule memory schedule, uint256 deadline, bytes32 domainSeparator)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                poller.SCHEDULE_REGISTRATION_TYPEHASH(),
                schedule.handler,
                schedule.authEpoch,
                schedule.funder,
                schedule.owner,
                schedule.salt,
                keccak256(schedule.staticInput),
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signRegister(ComposableCowPoller.Schedule memory schedule, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(funderPrivateKey, _registerDigest(schedule, deadline, poller.domainSeparator()));
    }

    function _revokeDigest(ComposableCowPoller.Schedule memory schedule, uint256 deadline, bytes32 domainSeparator)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                poller.REVOKE_TYPEHASH(),
                schedule.handler,
                schedule.authEpoch,
                schedule.funder,
                schedule.owner,
                schedule.salt,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signRevoke(ComposableCowPoller.Schedule memory schedule, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(funderPrivateKey, _revokeDigest(schedule, deadline, poller.domainSeparator()));
    }

    function _revoke(ComposableCowPoller.Schedule memory schedule) internal returns (bytes32 id) {
        vm.prank(schedule.funder);
        return poller.revoke(schedule.handler, schedule.owner, schedule.salt);
    }

    function _revokeWithSignature(
        ComposableCowPoller.Schedule memory schedule,
        uint256 deadline,
        bytes memory signature
    ) internal returns (bytes32 id) {
        return poller.revokeWithSignature(
            schedule.handler, schedule.funder, schedule.owner, schedule.salt, schedule.authEpoch, deadline, signature
        );
    }

    /// @dev The order's resolved start time `t0`, read back from the cabinet where
    ///      `createWithContext` stored it via `CurrentBlockTimestampFactory`.
    function _t0(bytes32 paramsHash) internal view returns (uint256) {
        return uint256(composableCow.cabinet(address(safe1), paramsHash));
    }

    /// @dev A registered schedule is stored under its appData-independent id.
    function test_register_storesSchedule() public {
        (,, bytes32 id) = _setupSchedule();

        (
            IConditionalOrderGenerator handler,
            uint96 authEpoch,
            address scheduleFunder,
            address owner,
            bytes32 salt,
            bytes memory staticInput
        ) = poller.schedules(id);
        assertEq(address(handler), address(twap), "handler stored");
        assertEq(authEpoch, 0, "initial authorization epoch stored");
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

        (,,,, bytes32 firstSalt,) = poller.schedules(firstId);
        (,,,, bytes32 secondSalt,) = poller.schedules(secondId);
        assertEq(firstSalt, SALT, "first schedule remains stored");
        assertEq(secondSalt, SECOND_SALT, "second schedule stored");
    }

    /// @dev A taken key is rejected, even for a different order, so a live order is never orphaned.
    function test_register_RevertWhen_alreadyRegistered() public {
        _register(_schedule(SALT, abi.encode(_bundle())));

        TWAPOrder.Data memory other = _bundle();
        other.partSellAmount = TWAP_PART_AMOUNT * 2;

        vm.prank(funder);
        vm.expectRevert(ComposableCowPoller.AlreadyRegistered.selector);
        poller.register(_schedule(SALT, abi.encode(other)));
    }

    /// @dev The hash the poller derives internally must equal `ComposableCoW.hash(params)`, since
    ///      the contract mirrors that formula instead of calling it. `pollFunds` depends on the
    ///      match too: it looks the order up in `singleOrders` by the derived key.
    function test_register_logsTheComposableCowOrderKey() public {
        (IConditionalOrder.ConditionalOrderParams memory params, bytes32 paramsHash,) = _setupSchedule();

        assertEq(paramsHash, composableCow.hash(params), "paramsHash is the ComposableCoW order key");
        assertTrue(composableCow.singleOrders(address(safe1), paramsHash), "the key resolves to a live order");
        assertEq(_expectedParamsHash(SALT, abi.encode(_bundle())), paramsHash, "the logged key matches");
    }

    /// @dev A replacement keeps the same `id` and the same indexed topics, so `paramsHash` is the
    ///      only thing in the log that reveals which order each registration pointed at. The key
    ///      has to be revoked first, since `register` rejects a taken one.
    function test_register_logIdentifiesTheReplacedOrder() public {
        bytes memory firstInput = abi.encode(_bundle());
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, firstInput);
        bytes32 id = poller.scheduleId(schedule);

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRegistered(id, address(safe1), funder, 0, _expectedParamsHash(SALT, firstInput));
        _register(schedule);

        TWAPOrder.Data memory other = _bundle();
        other.partSellAmount = TWAP_PART_AMOUNT * 2;
        bytes memory secondInput = abi.encode(other);

        bytes32 firstParamsHash = _expectedParamsHash(SALT, firstInput);
        bytes32 secondParamsHash = _expectedParamsHash(SALT, secondInput);
        assertTrue(firstParamsHash != secondParamsHash, "the two orders have distinct keys");

        _revoke(schedule);

        schedule.authEpoch = 1;
        schedule.staticInput = secondInput;
        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRegistered(id, address(safe1), funder, 1, secondParamsHash);
        assertEq(_register(schedule), id, "same id as the schedule it replaced");
    }

    /// @dev Only the funds source may register a schedule that draws on its own funds.
    function test_register_RevertWhen_notFunder() public {
        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.register(
            ComposableCowPoller.Schedule({
                handler: IConditionalOrderGenerator(address(twap)),
                authEpoch: 0,
                funder: funder, // attacker points at someone else's funds
                owner: address(safe1),
                salt: SALT,
                staticInput: abi.encode(_bundle())
            })
        );
    }

    function test_register_RevertWhen_staleAuthEpochAfterPreRegistrationRevoke() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        _revoke(schedule);

        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        _register(schedule);
    }

    function test_registerWithSignature_allowsArbitraryCallerWithEOASignature() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);

        vm.prank(makeAddr("arbitrary caller"));
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        assertEq(id, poller.scheduleId(schedule));
        (,, address storedFunder,,,) = poller.schedules(id);
        assertEq(storedFunder, funder, "schedule stored");
    }

    function test_registerWithSignature_allowsERC1271Signature() public {
        TestPollerERC1271Signer signer = new TestPollerERC1271Signer();
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.funder = address(signer);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = hex"c0ffee";
        bytes32 digest = _registerDigest(schedule, deadline, poller.domainSeparator());
        signer.allow(digest, signature);

        vm.prank(bob.addr);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        (,, address storedFunder,,,) = poller.schedules(id);
        assertEq(storedFunder, address(signer), "contract-funded schedule stored");
    }

    function test_registerWithSignature_acceptsEIP712Digest() public {
        ComposableCowPoller.Schedule memory schedule = ComposableCowPoller.Schedule({
            handler: IConditionalOrderGenerator(address(0x2222222222222222222222222222222222222222)),
            authEpoch: 0,
            funder: funder,
            owner: address(0x3333333333333333333333333333333333333333),
            salt: 0x4444444444444444444444444444444444444444444444444444444444444444,
            staticInput: hex"deadbeef"
        });
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _registerDigest(schedule, deadline, poller.domainSeparator());
        bytes memory signature = _sign(funderPrivateKey, digest);

        assertEq(poller.registerWithSignature(schedule, deadline, signature), poller.scheduleId(schedule));
    }

    function test_registerWithSignature_RevertWhen_replayed() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        vm.expectRevert(ComposableCowPoller.AlreadyRegistered.selector);
        poller.registerWithSignature(schedule, deadline, signature);

        (,, address storedFunder,,,) = poller.schedules(id);
        assertEq(storedFunder, funder, "replay does not change schedule");
    }

    function test_registerWithSignature_RevertWhen_expired() public {
        vm.warp(1 days);
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _signRegister(schedule, deadline);

        vm.expectRevert(ComposableCowPoller.SignatureExpired.selector);
        poller.registerWithSignature(schedule, deadline, signature);
    }

    function test_registerWithSignature_acceptsDeadlineAtCurrentTimestamp() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp;

        poller.registerWithSignature(schedule, deadline, _signRegister(schedule, deadline));
    }

    function test_registerWithSignature_allowsConcurrentSchedules() public {
        ComposableCowPoller.Schedule memory first = _schedule(SALT, abi.encode(_bundle()));
        ComposableCowPoller.Schedule memory second = _schedule(SECOND_SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory firstSignature = _signRegister(first, deadline);
        bytes memory secondSignature = _signRegister(second, deadline);

        bytes32 firstId = poller.registerWithSignature(first, deadline, firstSignature);
        bytes32 secondId = poller.registerWithSignature(second, deadline, secondSignature);

        assertEq(firstId, poller.scheduleId(first));
        assertEq(secondId, poller.scheduleId(second));
    }

    function test_registerWithSignature_RevertWhen_wrongSigner() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _registerDigest(schedule, deadline, poller.domainSeparator());

        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(schedule, deadline, _sign(alice.pk, digest));
    }

    function test_registerWithSignature_RevertWhen_scheduleChanges() public {
        ComposableCowPoller.Schedule memory signedSchedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(signedSchedule, deadline);
        ComposableCowPoller.Schedule memory changed = signedSchedule;

        changed.handler = IConditionalOrderGenerator(address(0x1111));
        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(changed, deadline, signature);

        changed = signedSchedule;
        changed.funder = address(0x2222);
        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(changed, deadline, signature);

        changed = signedSchedule;
        changed.owner = address(0x3333);
        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(changed, deadline, signature);

        changed = signedSchedule;
        changed.salt = SECOND_SALT;
        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(changed, deadline, signature);

        changed = signedSchedule;
        changed.staticInput = bytes("changed");
        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(changed, deadline, signature);

        changed = signedSchedule;
        changed.authEpoch = 1;
        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(changed, deadline, signature);
    }

    function test_registerWithSignature_RevertWhen_signedForDifferentDomain() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 chainId = block.chainid;
        vm.chainId(chainId + 1);
        bytes32 otherChainDomainSeparator = poller.domainSeparator();
        vm.chainId(chainId);
        bytes32 digest = _registerDigest(schedule, deadline, otherChainDomainSeparator);

        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(schedule, deadline, _sign(funderPrivateKey, digest));

        ComposableCowPoller otherPoller = new ComposableCowPoller(composableCow, ICowShedFactory(address(shedFactory)));
        digest = _registerDigest(schedule, deadline, otherPoller.domainSeparator());

        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(schedule, deadline, _sign(funderPrivateKey, digest));
    }

    function test_registerWithSignature_RevertWhen_replayedAfterRevoke() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);
        _revoke(schedule);

        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        poller.registerWithSignature(schedule, deadline, signature);

        schedule.authEpoch = 1;
        assertEq(
            poller.registerWithSignature(schedule, deadline, _signRegister(schedule, deadline)),
            id,
            "fresh signature reuses ID"
        );
    }

    function test_revoke_blocksPendingRegistrationSignature() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 id = poller.scheduleId(schedule);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, schedule.owner, funder);
        assertEq(_revoke(schedule), id, "derived id returned");

        (IConditionalOrderGenerator handler, uint96 authEpoch, address scheduleFunder, address owner,,) =
            poller.schedules(id);
        assertEq(address(handler), address(0), "no active schedule stored");
        assertEq(authEpoch, 1, "authorization epoch advanced");
        assertEq(scheduleFunder, address(0), "funder cleared");
        assertEq(owner, address(0), "no owner stored");

        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        poller.registerWithSignature(schedule, deadline, signature);
        schedule.authEpoch = 1;
        assertEq(
            poller.registerWithSignature(schedule, deadline, _signRegister(schedule, deadline)),
            id,
            "fresh signature registers"
        );
    }

    function test_revoke_cannotCancelAnotherFundersSignature() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);

        vm.prank(bob.addr);
        bytes32 bobId = poller.revoke(schedule.handler, schedule.owner, schedule.salt);

        bytes32 funderId = poller.scheduleId(schedule);
        assertTrue(bobId != funderId, "schedule IDs are namespaced by funder");
        assertEq(poller.registerWithSignature(schedule, deadline, signature), funderId);
    }

    /// @dev The funder can revoke, which clears active data and advances the authorization epoch.
    function test_revoke_clearsSchedule() public {
        (,, bytes32 id) = _setupSchedule();
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, address(safe1), funder);

        assertEq(_revoke(schedule), id, "registered id returned");

        (
            IConditionalOrderGenerator handler,
            uint96 authEpoch,
            address scheduleFunder,
            address owner,
            bytes32 salt,
            bytes memory staticInput
        ) = poller.schedules(id);
        assertEq(address(handler), address(0), "handler cleared");
        assertEq(authEpoch, 1, "authorization epoch advanced");
        assertEq(scheduleFunder, address(0), "funder cleared");
        assertEq(owner, address(0), "owner cleared");
        assertEq(salt, bytes32(0), "salt cleared");
        assertEq(staticInput, bytes(""), "static input cleared");
    }

    function test_revokeWithSignature_allowsArbitraryCallerWithEOASignature() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 id = _register(schedule);
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, address(safe1), funder);
        vm.prank(bob.addr);
        assertEq(_revokeWithSignature(schedule, deadline, _signRevoke(schedule, deadline)), id, "id returned");

        (IConditionalOrderGenerator handler, uint96 authEpoch, address scheduleFunder, address owner,,) =
            poller.schedules(id);
        assertEq(address(handler), address(0), "handler cleared");
        assertEq(authEpoch, 1, "authorization epoch advanced");
        assertEq(scheduleFunder, address(0), "funder cleared");
        assertEq(owner, address(0), "owner cleared");
    }

    function test_revokeWithSignature_allowsERC1271Signature() public {
        TestPollerERC1271Signer signer = new TestPollerERC1271Signer();
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.funder = address(signer);
        bytes32 id = _register(schedule);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = hex"c0ffee";
        signer.allow(_revokeDigest(schedule, deadline, poller.domainSeparator()), signature);

        vm.prank(bob.addr);
        _revokeWithSignature(schedule, deadline, signature);

        (IConditionalOrderGenerator handler, uint96 authEpoch, address scheduleFunder,,,) = poller.schedules(id);
        assertEq(address(handler), address(0), "handler cleared");
        assertEq(authEpoch, 1, "authorization epoch advanced");
        assertEq(scheduleFunder, address(0), "funder cleared");
    }

    function test_revokeWithSignature_RevertWhen_expired() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 id = _register(schedule);
        vm.warp(1 days);
        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _signRevoke(schedule, deadline);

        vm.expectRevert(ComposableCowPoller.SignatureExpired.selector);
        _revokeWithSignature(schedule, deadline, signature);

        (IConditionalOrderGenerator handler,,, address owner,,) = poller.schedules(id);
        assertEq(address(handler), address(twap), "schedule remains active");
        assertEq(owner, address(safe1), "owner retained");
    }

    function test_revokeWithSignature_RevertWhen_scheduleChanges() public {
        ComposableCowPoller.Schedule memory signedSchedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 signedId = _register(signedSchedule);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRevoke(signedSchedule, deadline);
        ComposableCowPoller.Schedule memory changedSchedule = signedSchedule;
        changedSchedule.salt = SECOND_SALT;

        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        _revokeWithSignature(changedSchedule, deadline, signature);

        (IConditionalOrderGenerator handler,,,,,) = poller.schedules(signedId);
        assertEq(address(handler), address(twap), "signed schedule remains active");
    }

    function test_revokeWithSignature_blocksPendingRegistrationSignature() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 id = poller.scheduleId(schedule);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory registerSignature = _signRegister(schedule, deadline);

        vm.prank(bob.addr);
        assertEq(_revokeWithSignature(schedule, deadline, _signRevoke(schedule, deadline)), id, "derived id returned");

        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        poller.registerWithSignature(schedule, deadline, registerSignature);
    }

    function test_revokeWithSignature_RevertWhen_scheduleRecreatedInNewAuthEpoch() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes32 id = _register(schedule);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRevoke(schedule, deadline);

        _revoke(schedule);
        ComposableCowPoller.Schedule memory recreatedSchedule = _schedule(SALT, abi.encode(_bundle()));
        recreatedSchedule.authEpoch = 1;
        _register(recreatedSchedule);

        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        _revokeWithSignature(schedule, deadline, signature);

        (IConditionalOrderGenerator handler, uint96 authEpoch,,,,) = poller.schedules(id);
        assertEq(address(handler), address(twap), "new authorization epoch remains active");
        assertEq(authEpoch, 1, "new authorization epoch retained");
    }

    /// @dev Funds move unconditionally: even if the owner already holds a balance (e.g. from another
    ///      concurrent order), the full part is still pulled, so orders never share funding.
    function test_pollFunds_movesFullAmountUnconditionally() public {
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        vm.warp(_t0(paramsHash));

        // The owner already holds an unrelated balance (e.g. funded for another order).
        deal(address(token0), address(safe1), TWAP_PART_AMOUNT);

        GPv2Order.Data memory order =
            twap.getTradeableOrder(address(safe1), address(poller), paramsHash, abi.encode(_bundle()), bytes(""));
        vm.expectEmit(true, true, true, true, address(poller));
        emit Pulled(id, GPv2Order.hash(order, composableCow.domainSeparator()), order.sellAmount);

        assertTrue(poller.pollFunds(id), "funds moved");

        assertEq(
            token0.balanceOf(address(safe1)), TWAP_PART_AMOUNT * 2, "full part pulled on top of the existing balance"
        );
        assertEq(token0.balanceOf(funder), TWAP_PART_AMOUNT * N - TWAP_PART_AMOUNT, "a full part left the funder");
    }

    /// @dev A repeated call in the same part is a no-op, even after settlement drains the owner.
    function test_pollFunds_idempotentWithinPartAfterSettlement() public {
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        vm.warp(_t0(paramsHash));

        assertTrue(poller.pollFunds(id), "funds moved");

        vm.prank(address(safe1));
        assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "part settled");
        assertEq(token0.balanceOf(address(safe1)), 0, "part settled");

        assertFalse(poller.pollFunds(id), "already funded, no-op");

        assertEq(token0.balanceOf(address(safe1)), 0, "next part not funded early");
        assertEq(token0.balanceOf(funder), TWAP_PART_AMOUNT * N - TWAP_PART_AMOUNT, "no extra pull");
    }

    /// @dev A handler returning A, then B, then A cannot refund A, even after schedule registration.
    function test_pollFunds_doesNotRefundEarlierDigestAfterReregister() public {
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        vm.warp(_t0(paramsHash));

        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        bytes memory handlerCall = abi.encodeCall(
            IConditionalOrderGenerator.getTradeableOrder,
            (address(safe1), address(poller), paramsHash, schedule.staticInput, bytes(""))
        );
        GPv2Order.Data memory orderA =
            twap.getTradeableOrder(address(safe1), address(poller), paramsHash, schedule.staticInput, bytes(""));
        GPv2Order.Data memory orderB = abi.decode(abi.encode(orderA), (GPv2Order.Data));
        orderB.appData = keccak256("second valid order");

        vm.mockCall(address(twap), handlerCall, abi.encode(orderA));
        assertTrue(poller.pollFunds(id), "first order funded");
        vm.prank(address(safe1));
        assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "first order settled");

        vm.clearMockedCalls();
        vm.mockCall(address(twap), handlerCall, abi.encode(orderB));
        assertTrue(poller.pollFunds(id), "second order funded");
        vm.prank(address(safe1));
        assertTrue(token0.transfer(bob.addr, TWAP_PART_AMOUNT), "second order settled");

        _revoke(schedule);

        schedule.authEpoch = 1;
        assertEq(_register(schedule), id, "same schedule id");

        vm.clearMockedCalls();
        vm.mockCall(address(twap), handlerCall, abi.encode(orderA));
        assertFalse(poller.pollFunds(id), "first order already funded, no-op");

        assertEq(token0.balanceOf(address(safe1)), 0, "first order not funded twice");
        assertEq(token0.balanceOf(funder), TWAP_PART_AMOUNT, "only two distinct orders funded");
        assertTrue(poller.funded(id, GPv2Order.hash(orderA, composableCow.domainSeparator())));
        assertTrue(poller.funded(id, GPv2Order.hash(orderB, composableCow.domainSeparator())));
    }

    /// @dev A failed ERC-20 transfer must not mark this part as funded.
    function test_pollFunds_RevertWhen_transferFromReturnsFalse() public {
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        vm.warp(_t0(paramsHash));

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
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        uint256 t0 = _t0(paramsHash);

        for (uint256 part = 0; part < N; part++) {
            vm.warp(t0 + part * FREQ);

            assertEq(token0.balanceOf(address(safe1)), 0, "owner empty before part");
            assertTrue(poller.pollFunds(id), "funds moved for this part");
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
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        vm.warp(_t0(paramsHash) + N * FREQ);

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
        (, bytes32 paramsHash, bytes32 id) = _setupSchedule();
        vm.warp(_t0(paramsHash));

        vm.prank(address(safe1));
        composableCow.remove(paramsHash);

        vm.expectRevert(ComposableCowPoller.OrderNotLive.selector);
        poller.pollFunds(id);
    }

    // --- registering from the funder's CowShed -----------------------------------------------

    /// @dev A shed may only register schedules that fund itself, so its schedules name it as owner.
    function _shedSchedule(bytes32 salt, bytes memory staticInput)
        internal
        view
        returns (ComposableCowPoller.Schedule memory)
    {
        return ComposableCowPoller.Schedule({
            handler: IConditionalOrderGenerator(address(twap)),
            authEpoch: 0,
            funder: funder,
            owner: funderShed,
            salt: salt,
            staticInput: staticInput
        });
    }

    function _registerFromShed(ComposableCowPoller.Schedule memory schedule) internal returns (bytes32 id) {
        vm.prank(funderShed);
        return poller.registerFromShed(schedule);
    }

    /// @dev Signs a hook bundle as the funder, deploying the shed first so its digest can be read.
    ///      The real factory deploys on first use in exactly the same way.
    function _signShedCalls(MockShedCall[] memory calls, bytes32 nonce) internal returns (bytes memory) {
        shedFactory.initializeProxy(funder);
        return _sign(funderPrivateKey, MockCowShed(payable(funderShed)).hashToSign(calls, nonce));
    }

    function _call(address target, bytes memory callData) internal pure returns (MockShedCall memory) {
        return MockShedCall({target: target, value: 0, callData: callData});
    }

    /// @dev The load-bearing invariant: the shed registers, but the ID belongs to the funder's
    ///      namespace. Nothing is keyed by the shed, so the funder keeps control of the key.
    function test_registerFromShed_storesScheduleNamespacedByFunder() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        bytes32 expectedId = poller.scheduleId(schedule);

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRegistered(expectedId, funderShed, funder, 0, _expectedParamsHash(SALT, abi.encode(_bundle())));
        assertEq(_registerFromShed(schedule), expectedId, "returns the funder-namespaced id");

        (
            IConditionalOrderGenerator handler,
            uint96 authEpoch,
            address storedFunder,
            address storedOwner,
            bytes32 storedSalt,
        ) = poller.schedules(expectedId);
        assertEq(address(handler), address(twap), "handler stored");
        assertEq(authEpoch, 0, "initial authorization epoch stored");
        assertEq(storedFunder, funder, "funder stored, not the shed");
        assertEq(storedOwner, funderShed, "shed stored as owner");
        assertEq(storedSalt, SALT, "salt stored");

        // The same fields keyed by the shed as funder are a different, untouched ID.
        ComposableCowPoller.Schedule memory shedAsFunder = schedule;
        shedAsFunder.funder = funderShed;
        (,, address strayFunder,,,) = poller.schedules(poller.scheduleId(shedAsFunder));
        assertEq(strayFunder, address(0), "nothing written under the shed's own namespace");
    }

    function test_registerFromShed_RevertWhen_callerIsRandomAddress() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));

        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.registerFromShed(schedule);
    }

    /// @dev A shed can only act for its own owner, so it cannot spend another funder's allowance.
    ///      The schedule names the caller as owner, so only the shed check can reject it.
    function test_registerFromShed_RevertWhen_callerIsAnotherFundersShed() public {
        address otherShed = shedFactory.proxyOf(makeAddr("otherFunder"));
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        schedule.owner = otherShed;

        vm.prank(otherShed);
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.registerFromShed(schedule);
    }

    /// @dev `proxyOf(0)` is a real derivable address, and a zero funder is the unused-ID sentinel.
    function test_registerFromShed_RevertWhen_funderIsZero() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        schedule.funder = address(0);

        vm.prank(shedFactory.proxyOf(address(0)));
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.registerFromShed(schedule);
    }

    /// @dev The shed may only fund itself: it cannot route the funder's tokens to a third party.
    function test_registerFromShed_RevertWhen_ownerIsNotCaller() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        schedule.owner = makeAddr("attacker");

        vm.prank(funderShed);
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.registerFromShed(schedule);
    }

    /// @dev Shares `_register`, so a taken key is rejected on the shed path too.
    function test_registerFromShed_RevertWhen_alreadyRegistered() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        _registerFromShed(schedule);

        vm.prank(funderShed);
        vm.expectRevert(ComposableCowPoller.AlreadyRegistered.selector);
        poller.registerFromShed(schedule);
    }

    /// @dev The funder's own revocation advances the epoch, so it also invalidates the shed's
    ///      pending registration. The shed can re-register in the new epoch.
    function test_registerFromShed_RevertWhen_staleAuthEpochAfterFunderRevoke() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        vm.prank(funder);
        bytes32 id = poller.revoke(schedule.handler, schedule.owner, schedule.salt);

        vm.prank(funderShed);
        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        poller.registerFromShed(schedule);

        schedule.authEpoch = 1;
        assertEq(_registerFromShed(schedule), id, "the shed registers in the new epoch");
    }

    function testFuzz_registerFromShed_RevertWhen_callerIsNotFunderShed(address caller) public {
        vm.assume(caller != funderShed);
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));

        vm.prank(caller);
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.registerFromShed(schedule);
    }

    /// @dev The direct path is untouched: it still rejects non-funders and still allows any owner.
    function test_register_directPathUnchangedByShedPath() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.owner = makeAddr("someSafe");
        assertEq(_register(schedule), poller.scheduleId(schedule), "arbitrary owner still allowed");

        ComposableCowPoller.Schedule memory second = _schedule(SECOND_SALT, abi.encode(_bundle()));
        vm.prank(funderShed);
        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.register(second);
    }

    // --- the attack the pinned factory rules out --------------------------------------------

    /// @dev `COWShedExecutorFactory`'s deployment path is permissionless and lets the *caller* pick
    ///      the trusted executor, who can then drive the shed with no signature at all. A shed it
    ///      deploys therefore proves nothing about its owner, so the poller must not accept one —
    ///      and must not trust `ownerOf`, which that factory happily populates.
    function test_registerFromShed_RevertWhen_shedCameFromExecutorFactory() public {
        MockCowShedExecutorFactory executorFactory = new MockCowShedExecutorFactory();
        address attacker = makeAddr("attacker");

        address hostileShed = executorFactory.initializeProxy(funder, attacker, bytes32(0));
        assertTrue(hostileShed != funderShed, "executor path derives a different address");
        assertEq(executorFactory.ownerOf(hostileShed), funder, "ownerOf claims the victim: why it is unused");
        assertEq(MockCowShed(payable(hostileShed)).trustedExecutor(), attacker, "attacker drives the shed");

        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        schedule.owner = hostileShed;

        // The precise rejection: this shed is not `proxyOf(funder)`, whatever `ownerOf` says.
        vm.prank(hostileShed);
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.registerFromShed(schedule);

        // And via the route that needs no signature at all, which is what makes it dangerous.
        MockShedCall[] memory calls = new MockShedCall[](1);
        calls[0] = _call(address(poller), abi.encodeCall(poller.registerFromShed, (schedule)));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(MockCowShed.CallReverted.selector, 0));
        MockCowShed(payable(hostileShed)).trustedExecuteHooks(calls);
    }

    function test_constructor_RevertWhen_shedFactoryIsZero() public {
        vm.expectRevert(ComposableCowPoller.InvalidCowShedFactory.selector);
        new ComposableCowPoller(composableCow, ICowShedFactory(address(0)));
    }

    function test_constructor_RevertWhen_shedFactoryHasNoCode() public {
        vm.expectRevert(ComposableCowPoller.InvalidCowShedFactory.selector);
        new ComposableCowPoller(composableCow, ICowShedFactory(makeAddr("notAFactory")));
    }

    // --- revoking from the funder's CowShed -------------------------------------------------

    function test_revokeFromShed_clearsScheduleNamespacedByFunder() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        bytes32 id = _registerFromShed(schedule);

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, funderShed, funder);
        vm.prank(funderShed);
        assertEq(
            poller.revokeFromShed(schedule.handler, funder, schedule.owner, schedule.salt),
            id,
            "revokes the funder-namespaced id"
        );

        (IConditionalOrderGenerator handler, uint96 authEpoch, address storedFunder,,,) = poller.schedules(id);
        assertEq(address(handler), address(0), "schedule cleared");
        assertEq(authEpoch, 1, "authorization epoch advanced");
        assertEq(storedFunder, address(0), "funder cleared");
    }

    /// @dev Documents why `revokeFromShed` exists: `revoke` derives the ID from `msg.sender`, so a
    ///      shed calling it burns an unrelated key and leaves the real schedule live.
    function test_revoke_fromShedHitsTheWrongNamespace() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        bytes32 id = _registerFromShed(schedule);

        vm.prank(funderShed);
        bytes32 strayId = poller.revoke(schedule.handler, schedule.owner, schedule.salt);

        assertTrue(strayId != id, "the shed's own namespace is a different key");
        (IConditionalOrderGenerator handler,,,,,) = poller.schedules(id);
        assertEq(address(handler), address(twap), "the real schedule is untouched");
    }

    /// @dev Containment: whatever the shed registered, the funder can revoke unilaterally.
    function test_revoke_funderCanRevokeShedRegisteredSchedule() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        bytes32 id = _registerFromShed(schedule);

        vm.prank(funder);
        assertEq(poller.revoke(schedule.handler, schedule.owner, schedule.salt), id, "funder owns the key");

        (IConditionalOrderGenerator handler,,,,,) = poller.schedules(id);
        assertEq(address(handler), address(0), "schedule cleared without the shed");
    }

    function test_revokeFromShed_RevertWhen_callerIsNotFunderShed() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        _registerFromShed(schedule);

        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.revokeFromShed(schedule.handler, funder, schedule.owner, schedule.salt);
    }

    function test_revokeFromShed_RevertWhen_funderIsZero() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));

        vm.prank(shedFactory.proxyOf(address(0)));
        vm.expectRevert(ComposableCowPoller.UnauthorizedShed.selector);
        poller.revokeFromShed(schedule.handler, address(0), schedule.owner, schedule.salt);
    }

    /// @dev Revocation is idempotent in effect but not in epoch: repeating it advances the epoch
    ///      again, as on the funder's own path.
    function test_revokeFromShed_repeatedAdvancesAuthEpoch() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        bytes32 id = _registerFromShed(schedule);

        vm.prank(funderShed);
        poller.revokeFromShed(schedule.handler, funder, schedule.owner, schedule.salt);

        vm.prank(funderShed);
        poller.revokeFromShed(schedule.handler, funder, schedule.owner, schedule.salt);

        (, uint96 authEpoch,,,,) = poller.schedules(id);
        assertEq(authEpoch, 2, "each revocation advances the epoch");
    }

    /// @dev The shed can pre-emptively cancel the current epoch before any registration lands,
    ///      same as the funder.
    function test_revokeFromShed_blocksPendingRegistration() public {
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));

        vm.prank(funderShed);
        poller.revokeFromShed(schedule.handler, funder, schedule.owner, schedule.salt);

        vm.prank(funderShed);
        vm.expectRevert(ComposableCowPoller.InvalidAuthEpoch.selector);
        poller.registerFromShed(schedule);
    }

    // --- end to end -------------------------------------------------------------------------

    /// @dev The flow this change exists for: one funder signature over a shed bundle that both
    ///      creates the TWAP and registers the schedule, then just-in-time funding per part with no
    ///      further signature. No ERC-1271 is needed here because the shed creates the order itself.
    function test_registerFromShed_endToEndSignedBundle() public {
        IConditionalOrder.ConditionalOrderParams memory params =
            super.createOrder(twap, SALT, abi.encode(_bundle()));
        ComposableCowPoller.Schedule memory schedule = _shedSchedule(SALT, abi.encode(_bundle()));
        bytes32 paramsHash = composableCow.hash(params);
        bytes32 id = poller.scheduleId(schedule);

        MockShedCall[] memory calls = new MockShedCall[](2);
        calls[0] = _call(
            address(composableCow),
            abi.encodeCall(
                composableCow.createWithContext, (params, currentBlockTimestampFactory, bytes(""), false)
            )
        );
        calls[1] = _call(address(poller), abi.encodeCall(poller.registerFromShed, (schedule)));

        bytes32 nonce = keccak256("jit-twap-setup");
        bytes memory signature = _signShedCalls(calls, nonce);

        // Anyone may relay the funder's signed bundle: a solver hook, a relayer, a keeper.
        vm.prank(makeAddr("relayer"));
        shedFactory.executeHooks(calls, nonce, funder, signature);

        assertTrue(composableCow.singleOrders(funderShed, paramsHash), "shed owns the order");
        (,, address storedFunder, address storedOwner,,) = poller.schedules(id);
        assertEq(storedFunder, funder, "funder pays");
        assertEq(storedOwner, funderShed, "shed receives");

        // Capital stays with the funder until each part needs it.
        deal(address(token0), funder, TWAP_PART_AMOUNT * N);
        deal(address(token0), funderShed, 0);
        vm.prank(funder);
        token0.approve(address(poller), TWAP_PART_AMOUNT * N);

        uint256 t0 = uint256(composableCow.cabinet(funderShed, paramsHash));
        for (uint256 part; part < N; ++part) {
            vm.warp(t0 + part * FREQ);
            assertTrue(poller.pollFunds(id), "part funded");
            assertEq(
                token0.balanceOf(funderShed), TWAP_PART_AMOUNT * (part + 1), "one part pulled per window"
            );
            // A second call inside the same window is a no-op, so a repeated hook cannot double-pull.
            assertFalse(poller.pollFunds(id), "already funded this part");
        }
        assertEq(token0.balanceOf(funder), 0, "funder fully drawn down across the schedule");
    }
}
