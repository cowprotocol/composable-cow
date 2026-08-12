// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {GPv2Order} from "cowprotocol/contracts/libraries/GPv2Order.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IConditionalOrder, IValueFactory, BaseComposableCoWTest} from "test/ComposableCoW.base.t.sol";

import {TWAP} from "src/types/twap/TWAP.sol";
import {TWAPOrder} from "src/types/twap/libraries/TWAPOrder.sol";
import {ComposableCowPoller} from "src/types/ComposableCowPoller.sol";
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
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant REGISTER_TYPEHASH = keccak256(
        "Register(address handler,address funder,address owner,bytes32 salt,bytes staticInput,uint256 deadline)"
    );
    uint256 constant TWAP_PART_AMOUNT = 100e18;
    uint256 constant LIMIT = 1e18;
    uint256 constant N = 3;
    uint256 constant FREQ = 1 hours;
    bytes32 constant SALT = keccak256("twap");
    bytes32 constant SECOND_SALT = keccak256("second twap");

    ComposableCowPoller poller;
    IValueFactory currentBlockTimestampFactory;

    address funder;
    uint256 funderPrivateKey;

    event ScheduleRegistered(bytes32 indexed id, address indexed owner, address indexed funder, bytes32 paramsHash);
    event ScheduleRevoked(bytes32 indexed id, address indexed owner, address indexed funder);
    event Pulled(bytes32 indexed id, bytes32 indexed orderDigest, uint256 amount);

    function setUp() public virtual override(BaseComposableCoWTest) {
        super.setUp();

        twap = new TWAP(composableCow);
        currentBlockTimestampFactory = new CurrentBlockTimestampFactory();
        poller = new ComposableCowPoller(composableCow);
        funderPrivateKey = uint256(keccak256("funder"));
        funder = vm.addr(funderPrivateKey);
        vm.label(funder, "funder");

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
            funder: funder,
            owner: address(safe1),
            salt: salt,
            staticInput: staticInput
        });
    }

    function _expectedParamsHash(bytes32 salt, bytes memory staticInput) internal view returns (bytes32) {
        return composableCow.hash(
            IConditionalOrder.ConditionalOrderParams({
                handler: IConditionalOrder(address(twap)), salt: salt, staticInput: staticInput
            })
        );
    }

    function _register(ComposableCowPoller.Schedule memory schedule) internal returns (bytes32 id) {
        vm.prank(schedule.funder);
        id = poller.register(schedule);
    }

    function _domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("ComposableCowPoller"), keccak256("1"), chainId, verifyingContract)
        );
    }

    function _registerDigest(
        ComposableCowPoller.Schedule memory schedule,
        uint256 deadline,
        uint256 chainId,
        address verifyingContract
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                REGISTER_TYPEHASH,
                schedule.handler,
                schedule.funder,
                schedule.owner,
                schedule.salt,
                keccak256(schedule.staticInput),
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(chainId, verifyingContract), structHash));
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
        return _sign(funderPrivateKey, _registerDigest(schedule, deadline, block.chainid, address(poller)));
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

    /// @dev A taken key is rejected, even for a different order, so a live order is never orphaned.
    function test_register_RevertWhen_alreadyRegistered() public {
        _register(_schedule(SALT, abi.encode(_bundle())));

        TWAPOrder.Data memory other = _bundle();
        other.partSellAmount = TWAP_PART_AMOUNT * 2;

        vm.prank(funder);
        vm.expectRevert(ComposableCowPoller.AlreadyRegistered.selector);
        poller.register(_schedule(SALT, abi.encode(other)));
    }

    /// @dev Revoked keys remain occupied so an old registration signature can never restore them.
    function test_register_RevertWhen_previouslyRevoked() public {
        bytes memory staticInput = abi.encode(_bundle());
        bytes32 id = _register(_schedule(SALT, staticInput));

        vm.prank(funder);
        poller.revoke(id);

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

    function test_register_RevertWhen_handlerIsZero() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.handler = IConditionalOrderGenerator(address(0));

        vm.prank(funder);
        vm.expectRevert(ComposableCowPoller.InvalidHandler.selector);
        poller.register(schedule);
    }

    function test_registerWithSignature_allowsArbitraryCallerWithEOASignature() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);

        vm.prank(bob.addr);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        assertEq(id, poller.scheduleId(schedule));
        (, address storedFunder,,,) = poller.schedules(id);
        assertEq(storedFunder, funder, "schedule stored");
    }

    function test_registerWithSignature_allowsERC1271Signature() public {
        TestPollerERC1271Signer signer = new TestPollerERC1271Signer();
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        schedule.funder = address(signer);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = hex"c0ffee";
        bytes32 digest = _registerDigest(schedule, deadline, block.chainid, address(poller));
        signer.allow(digest, signature);

        vm.prank(bob.addr);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        (, address storedFunder,,,) = poller.schedules(id);
        assertEq(storedFunder, address(signer), "contract-funded schedule stored");
    }

    /// @dev The signature was generated independently with `cast wallet sign --data` from typed
    ///      data that declares `staticInput` as `bytes`.
    function test_registerWithSignature_matchesEIP712ReferenceVector() public {
        ComposableCowPoller.Schedule memory schedule = ComposableCowPoller.Schedule({
            handler: IConditionalOrderGenerator(address(0x2222222222222222222222222222222222222222)),
            funder: address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266),
            owner: address(0x3333333333333333333333333333333333333333),
            salt: 0x4444444444444444444444444444444444444444444444444444444444444444,
            staticInput: hex"deadbeef"
        });
        bytes memory signature =
            hex"c3924db920a1f5d2894df4e5db336fd8fd51e0c84e0e2371482fa9daf4e7b0574415070999401e04df6d6a7dae2e283676523ed6f14ec4f3feac246440eca0081c";

        bytes32 digest =
            _registerDigest(schedule, 1_234_567_890, 1, address(0x1111111111111111111111111111111111111111));

        assertEq(ECDSA.recover(digest, signature), schedule.funder, "matches reference signer");
    }

    function test_registerWithSignature_RevertWhen_replayed() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        vm.expectRevert(ComposableCowPoller.AlreadyRegistered.selector);
        poller.registerWithSignature(schedule, deadline, signature);

        (, address storedFunder,,,) = poller.schedules(id);
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
        bytes32 digest = _registerDigest(schedule, deadline, block.chainid, address(poller));

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

    }

    function test_registerWithSignature_RevertWhen_signedForDifferentChain() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _registerDigest(schedule, deadline, block.chainid + 1, address(poller));

        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(schedule, deadline, _sign(funderPrivateKey, digest));
    }

    function test_registerWithSignature_RevertWhen_signedForDifferentPoller() public {
        ComposableCowPoller otherPoller = new ComposableCowPoller(composableCow);
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _registerDigest(schedule, deadline, block.chainid, address(otherPoller));

        vm.expectRevert(ComposableCowPoller.InvalidSignature.selector);
        poller.registerWithSignature(schedule, deadline, _sign(funderPrivateKey, digest));
    }

    function test_registerWithSignature_RevertWhen_replayedAfterRevoke() public {
        ComposableCowPoller.Schedule memory schedule = _schedule(SALT, abi.encode(_bundle()));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signRegister(schedule, deadline);
        bytes32 id = poller.registerWithSignature(schedule, deadline, signature);

        vm.prank(funder);
        poller.revoke(id);

        vm.expectRevert(ComposableCowPoller.AlreadyRegistered.selector);
        poller.registerWithSignature(schedule, deadline, signature);
    }

    /// @dev The funder can revoke, which clears active data but retains the used-ID marker.
    function test_revoke_clearsActiveSchedule() public {
        (,, bytes32 id) = _setupSchedule();

        vm.expectEmit(true, true, true, true, address(poller));
        emit ScheduleRevoked(id, address(safe1), funder);

        vm.prank(funder);
        poller.revoke(id);

        (
            IConditionalOrderGenerator handler,
            address scheduleFunder,
            address owner,
            bytes32 salt,
            bytes memory staticInput
        ) = poller.schedules(id);
        assertEq(address(handler), address(0), "handler cleared");
        assertEq(scheduleFunder, funder, "used-id marker retained");
        assertEq(owner, address(0), "owner cleared");
        assertEq(salt, bytes32(0), "salt cleared");
        assertEq(staticInput, bytes(""), "static input cleared");

        vm.prank(funder);
        vm.expectRevert(ComposableCowPoller.NoSchedule.selector);
        poller.revoke(id);
    }

    /// @dev Only the funds source may revoke.
    function test_revoke_RevertWhen_notFunder() public {
        (,, bytes32 id) = _setupSchedule();

        vm.expectRevert(ComposableCowPoller.OnlyFunder.selector);
        poller.revoke(id);
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

    function test_pollFunds_RevertWhen_revoked() public {
        (,, bytes32 id) = _setupSchedule();
        vm.prank(funder);
        poller.revoke(id);

        vm.expectRevert(ComposableCowPoller.NoSchedule.selector);
        poller.pollFunds(id);
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
}
