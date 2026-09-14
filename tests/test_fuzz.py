import dataclasses
import os
import logging
import time
from collections import defaultdict
from dataclasses import dataclass
from typing import Callable, TypeVar

_T = TypeVar("_T")

from ordered_set import OrderedSet
from wake.testing import *
from wake.testing.fuzzing import *

from pytypes.src.ComposableCoW import ComposableCoW
from pytypes.src.interfaces.IConditionalOrder import IConditionalOrder, IConditionalOrderGenerator
from pytypes.src.interfaces.IAggregatorV3Interface import IAggregatorV3Interface
from pytypes.src.interfaces.IValueFactory import IValueFactory
from pytypes.src.types.ComposableCowPoller import ComposableCowPoller, ICowShedFactory
from pytypes.src.types.TradeAboveThreshold import TradeAboveThreshold
from pytypes.src.types.StopLoss import StopLoss
from pytypes.src.types.twap.TWAP import TWAP
from pytypes.src.types.twap.libraries.TWAPOrder import TWAPOrder
from pytypes.lib.cowprotocol.src.contracts.interfaces.IERC20 import IERC20
from pytypes.tests.PollerMocks import PollerTestHandler, PollerTestToken, MockAggregatorV3, MockERC1271Wallet

# Real mainnet deployments (chain id 1); the poller talks to both, so both are forked, not mocked.
COMPOSABLE_COW = ComposableCoW("0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74")
# COWShedForComposableCoW factory: its only deployment path derives the proxy from the owner alone,
# so a call from `proxyOf(funder)` proves the funder authorized it, and its sheds forward ERC-1271 to
# ComposableCoW. Its sheds expose the `initializeProxy(address)` + `trustedExecuteHooks` owner path
# the *FromShed flows drive.
COW_SHED_FACTORY = ICowShedFactory("0x5E284e80F3bd6A7D80A8500D9c49878028110848")

# Real handlers, used by the register / revoke flows purely as opaque schedule-key / paramsHash
# material -- the poller never calls them there. The poll flows need an order they can predict, so
# they use the controllable mock handler or one of the three real handlers modelled below.
REAL_HANDLERS = [
    IConditionalOrderGenerator("0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5"),  # TWAP
    IConditionalOrderGenerator("0x412c36e5011CD2517016D243a2dfB37f73A242E7"),  # StopLoss
    IConditionalOrderGenerator("0xdaF33924925E03C9cC3a10D434016D6cFad0aDd5"),  # GoodAfterTime
    IConditionalOrderGenerator("0x812308712a6D1367f437E1c1e4af85C854E1e9f6"),  # TradeAboveThreshold
    IConditionalOrderGenerator("0x519BA24e959E33b3B6220CA98bd353d8c2D89920"),  # PerpetualStableSwap
]

# TradeAboveThreshold, driven end-to-end by pollFunds: once `sellToken.balanceOf(owner)` reaches the
# static threshold it returns a full-balance market sell whose validTo is bucketed by
# `validityBucketSeconds`; below it, PollTryNextBlock("balance insufficient"). Modelled in `_poll_tat`.
TRADE_ABOVE_THRESHOLD = TradeAboveThreshold("0x812308712a6D1367f437E1c1e4af85C854E1e9f6")
TAT_BALANCE_INSUFFICIENT = "balance insufficient"

# TWAP and StopLoss (addresses from networks.json), also driven end-to-end through pollFunds. Unlike
# the other three order types, these produce a discrete order whose sellAmount is fixed in the
# staticInput, which is what makes them usable with just-in-time funding. Modelled in `_poll_twap` /
# `_poll_stoploss`.
TWAP_HANDLER = TWAP("0x6cF1e9cA41f7611dEf408122793c358a3d11E5a5")
STOP_LOSS_HANDLER = StopLoss("0x412c36e5011CD2517016D243a2dfB37f73A242E7")

# CurrentBlockTimestampFactory. With `createWithContext` it writes the current block timestamp into
# ComposableCoW's cabinet, which becomes the start time of a `t0 == 0` TWAP bundle -- the only path
# that exercises the poller passing a non-zero `ctx` (= paramsHash) into getTradeableOrder.
CURRENT_BLOCK_TIMESTAMP_FACTORY = IValueFactory("0x52eD56Da04309Aca4c3FECC595298d80C2f16BAc")

# TWAP OrderNotValid reasons: the handler refuses outside a part's live window and pollFunds
# propagates the revert verbatim.
TWAP_BEFORE_START = "before twap start"
TWAP_AFTER_FINISH = "after twap finish"
TWAP_NOT_WITHIN_SPAN = "not within span"

# StopLoss handler revert reasons. `order expired` / `oracle invalid price` are permanent
# (OrderNotValid); `oracle stale price` / `strike not reached` are retryable (PollTryNextBlock).
SL_ORDER_EXPIRED = "order expired"
SL_ORACLE_INVALID_PRICE = "oracle invalid price"
SL_ORACLE_STALE_PRICE = "oracle stale price"
SL_STRIKE_NOT_REACHED = "strike not reached"

# Real ERC20s used as `sellToken` on some pollFunds success paths, so the transfer also runs against
# production bytecode -- including USDT, whose transferFrom returns no bool.
REAL_TOKEN_ADDRS = [
    "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",  # WETH (18)
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",  # USDC (6, proxy)
    "0x6B175474E89094C44Da98b954EedeAC495271d0F",  # DAI  (18)
    "0xdAC17F958D2ee523a2206206994597C13D831ec7",  # USDT (6, no bool return)
]

# Small salt pool so schedule ids collide often enough to keep hitting AlreadyRegistered and the
# revoke-and-reuse path, without saturating.
SALTS = [bytes32(f"salt-{i}".encode().ljust(32, b"\x00")) for i in range(48)]

# GPv2 order constants (GPv2Order.sol), for building orders and hashing them independently.
GPV2_ORDER_TYPE_HASH = bytes32(bytes.fromhex("d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489"))
KIND_SELL = bytes32(bytes.fromhex("f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775"))
KIND_BUY = bytes32(bytes.fromhex("6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc"))
BALANCE_ERC20 = bytes32(bytes.fromhex("5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9"))
BALANCE_EXTERNAL = bytes32(bytes.fromhex("abee3b73373acd583a130924aad6dc38cfdc44ba0555ba94ce2ff63980ea0632"))
BALANCE_INTERNAL = bytes32(bytes.fromhex("4ac99ace14ee0a5ef932dc609df0943ab7ac16b7583634612f8dc35a4289a6ce"))

MAX_UINT = (1 << 256) - 1

# For recomputing the poller's domain separator independently.
EIP712_DOMAIN_TYPEHASH = keccak256(
    b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


@dataclass
class ScheduleRegistration(Struct):
    handler: Address
    authEpoch: uint96
    funder: Address
    owner: Address
    salt: bytes32
    staticInput: bytes
    deadline: uint256


@dataclass
class ShedCall(Struct):
    target: Address
    value: uint256
    callData: bytes
    allowFailure: bool
    isDelegatecall: bool


@dataclass
class Revoke(Struct):
    handler: Address
    authEpoch: uint96
    funder: Address
    owner: Address
    salt: bytes32
    deadline: uint256


@dataclass
class TwapOrder:
    """Mirror of a TWAP schedule's staticInput (TWAPOrder.Data), so the poll flow can recompute the
    current part's order (sellAmount == partSellAmount, plus the per-part validTo). `t0` is always
    concrete and nonzero, so the handler never reads the cabinet."""
    sell_token: Address
    buy_token: Address
    receiver: Address
    part_sell_amount: int
    min_part_limit: int
    t0: int
    n: int
    t: int
    span: int
    app_data: bytes32


@dataclass
class StopLossOrder:
    """Mirror of a StopLoss schedule's staticInput (StopLoss.Data). Every field of the order is fixed
    by the staticInput, so its digest is constant; the two oracles only decide whether an order is
    produced at all. `sell_dec` / `buy_dec` are the mock oracles' immutable decimals."""
    sell_token: Address
    buy_token: Address
    sell_amount: int
    buy_amount: int
    app_data: bytes32
    receiver: Address
    is_sell_order: bool
    is_partially_fillable: bool
    valid_to: int
    sell_oracle: Address
    buy_oracle: Address
    sell_dec: int
    buy_dec: int
    strike: int
    max_stale: int


@dataclass
class TatOrder:
    """Mirror of a TradeAboveThreshold schedule's staticInput. The order is balance-driven, so it has
    to be recomputed at poll time rather than stored as a fixed OrderSpec."""
    sell_token: Address
    buy_token: Address
    receiver: Address
    validity: int
    threshold: int
    app_data: bytes32


def random_bytes32() -> bytes32:
    # bytes32 subclasses `bytes`, so an int arg would be read as a length, not a value.
    return bytes32(random_bytes(32))


class ComposableCowPollerTest(FuzzTest):
    poller: ComposableCowPoller
    mock_handler: PollerTestHandler
    tokens: list[PollerTestToken]
    real_tokens: list[IERC20]
    real_token_addrs: OrderedSet
    token_by_addr: dict[Address, PollerTestToken | IERC20]
    token_mode: dict[Address, int]
    domain_separator: bytes32
    # Oracle pool for the StopLoss handler. Decimals are fixed at deploy; answer / staleDelay are set
    # right before each poll to pick the branch.
    oracles: list[MockAggregatorV3]
    oracle_dec: dict[Address, int]
    # funder -> its CowShed proxy. A pure CREATE2 derivation, so constant: cached at setup instead of
    # a `proxyOf` view call in every flow.
    sheds: dict[Address, Address]
    # ERC-1271 contract funders, each authorizing one fixed owner EOA (`wallet_owner`, for signing).
    erc1271_wallets: list[MockERC1271Wallet]
    wallet_owner: dict[Address, Account]
    # Set after the first sequence's one-time forked-handler oracle self-checks (see pre_sequence).
    _oracles_validated: bool

    # id -> the currently-registered schedule (active schedules only).
    schedules: dict[bytes32, ComposableCowPoller.Schedule]
    # id -> the authorization epoch the poller stores. Tracked for every id ever touched, so the
    # invariant can also check revoked (inactive) ids.
    auth_epochs: dict[bytes32, int]
    all_ids: OrderedSet
    # id -> order model, or None when the schedule is not pollable (unmodelled handler, garbage
    # staticInput, or shed-owned). The model's type picks which poll path runs.
    order_specs: dict[bytes32, PollerTestHandler.OrderSpec | TatOrder | TwapOrder | StopLossOrder | None]
    # (owner, paramsHash) authorized as a single order in ComposableCoW. Independent of poller state.
    created: OrderedSet
    # Every (owner, paramsHash) ever authorized, never pruned, so the invariant can also check that
    # removed pairs read back False. `_created_check_idx` rotates the window it checks.
    all_created_pairs: OrderedSet
    _created_check_idx: int
    # id -> set of order digests already funded. Must survive revoke + re-registration.
    funded: dict[bytes32, OrderedSet]
    # token -> account address -> balance mirror.
    balances: dict[PollerTestToken | IERC20, dict[Address, int]]

    def pre_sequence(self) -> None:
        self.poller = ComposableCowPoller.deploy(COMPOSABLE_COW, COW_SHED_FACTORY)
        self.mock_handler = PollerTestHandler.deploy()

        # Four ERC20 flavours: standard, USDT-style (no return), returns-false, malformed. The last
        # two exist to exercise the GPv2SafeERC20 result handling the poller relies on.
        self.tokens = [
            PollerTestToken.deploy("Std", "STD", 18, 0),
            PollerTestToken.deploy("NoRet", "NRT", 6, 1),
            PollerTestToken.deploy("False", "FLS", 18, 2),
            PollerTestToken.deploy("Malf", "MLF", 8, 3),
        ]
        self.real_tokens = [IERC20(a) for a in REAL_TOKEN_ADDRS]
        self.real_token_addrs = OrderedSet([t.address for t in self.real_tokens])
        self.token_by_addr = {t.address: t for t in self.tokens}
        for rt in self.real_tokens:
            self.token_by_addr[rt.address] = rt
        self.token_mode = {t.address: m for t, m in zip(self.tokens, [0, 1, 2, 3])}

        self.domain_separator = COMPOSABLE_COW.domainSeparator()

        # Resolve the forked handlers' reverts (OrderNotValid / PollTryNextBlock) to typed error
        # classes; without a resolver, a forked contract's errors surface as untyped externals.
        TRADE_ABOVE_THRESHOLD.pytypes_resolver = TradeAboveThreshold
        TWAP_HANDLER.pytypes_resolver = TWAP
        STOP_LOSS_HANDLER.pytypes_resolver = StopLoss

    # Mix of 8-decimal (typical USD feed) and 18-decimal feeds so the strike trigger's price scaling
    # is exercised both ways.
        self.oracles = [
            MockAggregatorV3.deploy(8),
            MockAggregatorV3.deploy(8),
            MockAggregatorV3.deploy(18),
            MockAggregatorV3.deploy(18),
        ]
        self.oracle_dec = {o.address: d for o, d in zip(self.oracles, [8, 8, 18, 18])}

    # ERC-1271 contract funders for the smart-wallet register / revoke path.
        self.erc1271_wallets = []
        self.wallet_owner = {}
        for owner_acc in chain.accounts[:3]:
            w = MockERC1271Wallet.deploy(owner_acc)
            self.erc1271_wallets.append(w)
            self.wallet_owner[w.address] = owner_acc

        self.schedules = {}
        self.auth_epochs = defaultdict(lambda: 0)
        self.all_ids = OrderedSet([])
        self.order_specs = {}
        self.created = OrderedSet([])
        self.all_created_pairs = OrderedSet([])
        self._created_check_idx = 0
        self.funded = defaultdict(lambda: OrderedSet([]))  # type: ignore[assignment]
        self.balances = {t: defaultdict(lambda: 0) for t in self.tokens}
        # Real tokens: baseline every chain account's current on-chain balance, then track deltas.
        for rt in self.real_tokens:
            bal: dict = defaultdict(lambda: 0)
            for acc in chain.accounts:
                bal[acc.address] = rt.balanceOf(acc)
            self.balances[rt] = bal

    # Blanket approvals so allowance is never the limiting factor by default (the mock treats a max
    # allowance as infinite). The insufficient-allowance case sets its own and restores it.
        for acc in chain.accounts:
            for token in self.tokens:
                token.approve(self.poller, MAX_UINT, from_=acc)
            for rt in self.real_tokens:
                rt.approve(self.poller, MAX_UINT, from_=acc)

        # create a shed for each user (for the *FromShed flows) and cache the deterministic proxy
        # address so flows never need a `proxyOf` view call.
        self.sheds = {}
        for acc in chain.accounts:
            COW_SHED_FACTORY.transact(abi.encode_with_signature("initializeProxy(address)", acc))
            self.sheds[acc.address] = COW_SHED_FACTORY.proxyOf(acc)

    # Deterministic (forked handlers + pure hashing), so the result is the same every sequence. Run
    # once rather than repeating the forked view calls on all 100 pre_sequences.
        if not getattr(self, "_oracles_validated", False):
            self._validate_oracles()
            self._oracles_validated = True

    # ------------------------------------------------------------------ oracle self-checks

    def _validate_oracles(self) -> None:
        """Check the Python hash and order formulas against the on-chain implementations, so a
        formula bug fails at setup instead of quietly weakening every assertion. View calls only."""
        # This is the same domain `_domain()` builds for signing; a silently-wrong one would
        # otherwise only ever show up as InvalidSignature in the signed flows.
        expected_domain = keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH, keccak256(b"ComposableCowPoller"), keccak256(b"1"),
            uint256(chain.chain_id), self.poller.address))
        assert self.poller.domainSeparator() == expected_domain, "domain separator oracle mismatch"

        # CurrentBlockTimestampFactory (used by flow_twap_cabinet) must be the real deployment: it
        # returns the current block timestamp as bytes32. A wrong/code-less address would revert here.
        factory_val = int.from_bytes(CURRENT_BLOCK_TIMESTAMP_FACTORY.getValue(b""), "big")
        assert factory_val >= 1_600_000_000, "CurrentBlockTimestampFactory not returning a timestamp"

        # The schedule id is the key for every register / revoke / poll, so check `_get_id` against
        # the poller's own `scheduleId` rather than relying on the event assertions alone.
        id_probe = ComposableCowPoller.Schedule(
            handler=self.mock_handler, authEpoch=uint96(0), funder=random_account().address,
            owner=random_account().address, salt=random_bytes32(), staticInput=random_bytes(0, 20))
        assert self.poller.scheduleId(id_probe) == self._get_id(
            id_probe.funder, self.mock_handler, id_probe.owner, id_probe.salt), "scheduleId oracle mismatch"

        params = IConditionalOrder.ConditionalOrderParams(
            handler=self.mock_handler, salt=random_bytes32(), staticInput=random_bytes(0, 40)
        )
        assert keccak256(abi.encode(params)) == COMPOSABLE_COW.hash(params), "paramsHash oracle mismatch"

        spec = self._random_spec()
        spec = dataclasses.replace(spec, revertOrder=False)
        static = abi.encode(spec)
        order = self.mock_handler.getTradeableOrder(Address(0), Address(0), bytes32(0), static, b"")
        assert self._order_digest(spec) == self.mock_handler.hashOrder(order, self.domain_separator), \
            "orderDigest oracle mismatch"

        # TAT order model against the real handler, in a snapshot so the probe mint does not pollute
        # the balance mirror.
        with chain.snapshot_and_revert():
            tat_static, tat = self._random_tat()
            probe_owner = random_account()
            token = self.token_by_addr[tat.sell_token]
            assert isinstance(token, PollerTestToken)
            token.mint(probe_owner, tat.threshold + 1000, from_=random_account())
            order = TRADE_ABOVE_THRESHOLD.getTradeableOrder(
                probe_owner, self.poller.address, bytes32(0), tat_static, b"")
            assert order.sellToken.address == tat.sell_token
            assert order.buyToken.address == tat.buy_token
            assert order.receiver == tat.receiver
            assert order.sellAmount == tat.threshold + 1000  # full owner balance
            assert order.buyAmount == 1
            assert order.feeAmount == 0
            assert order.kind == KIND_SELL
            assert order.partiallyFillable is False
            assert order.sellTokenBalance == BALANCE_ERC20
            assert order.buyTokenBalance == BALANCE_ERC20
            assert order.appData == tat.app_data
            # validTo is a bucket end. Checking `bucket(validTo - 1) == validTo` validates the
            # formula without needing to know the timestamp the handler actually saw.
            assert order.validTo == self._valid_to_bucket(order.validTo - 1, tat.validity), \
                "TAT validTo bucket oracle mismatch"
            # digest formula on the real handler's order
            assert self._tat_digest(tat, order.sellAmount, order.validTo) == \
                self.mock_handler.hashOrder(order, self.domain_separator), "TAT digest oracle mismatch"

        # TWAP order model against the real handler, on a live bundle (t0 in the past, span 0).
        with chain.snapshot_and_revert():
            tw_static, tw = self._random_twap(force_live=True)
            order = TWAP_HANDLER.getTradeableOrder(
                random_account(), self.poller.address, bytes32(0), tw_static, b"")
            assert order.sellToken.address == tw.sell_token
            assert order.buyToken.address == tw.buy_token
            assert order.receiver == tw.receiver
            assert order.sellAmount == tw.part_sell_amount
            assert order.buyAmount == tw.min_part_limit
            assert order.feeAmount == 0
            assert order.kind == KIND_SELL
            assert order.partiallyFillable is False
            assert order.sellTokenBalance == BALANCE_ERC20
            assert order.buyTokenBalance == BALANCE_ERC20
            assert order.appData == tw.app_data
            # validTo is the inclusive end of its part, so re-running the formula at ts == validTo
            # must reproduce it. Pins down the `- 1` without knowing the exact call-block timestamp.
            assert self._twap_valid_to(tw, order.validTo) == order.validTo, \
                "TWAP validTo formula mismatch"
            assert self._twap_digest(tw, order.validTo) == \
                self.mock_handler.hashOrder(order, self.domain_separator), "TWAP digest oracle mismatch"

        # StopLoss order model against the real handler, forced into the triggered branch: base tiny
        # / quote huge => rate <= strike, both fresh, validTo far out.
        with chain.snapshot_and_revert():
            sl_static, sl = self._random_stoploss(force_success=True)
            o_sell = self._oracle(sl.sell_oracle)
            o_buy = self._oracle(sl.buy_oracle)
            probe = random_account()
            o_sell.setAnswer(1, from_=probe)
            o_buy.setAnswer(10 ** 30, from_=probe)
            o_sell.setStaleDelay(0, from_=probe)
            o_buy.setStaleDelay(0, from_=probe)
            assert self._sl_triggered(1, sl.sell_dec, 10 ** 30, sl.buy_dec, sl.strike), \
                "StopLoss probe should be in the triggered branch"
            order = STOP_LOSS_HANDLER.getTradeableOrder(
                random_account(), self.poller.address, bytes32(0), sl_static, b"")
            assert order.sellToken.address == sl.sell_token
            assert order.buyToken.address == sl.buy_token
            assert order.receiver == sl.receiver
            assert order.sellAmount == sl.sell_amount
            assert order.buyAmount == sl.buy_amount
            assert order.validTo == sl.valid_to
            assert order.appData == sl.app_data
            assert order.feeAmount == 0
            assert order.kind == (KIND_SELL if sl.is_sell_order else KIND_BUY)
            assert order.partiallyFillable is sl.is_partially_fillable
            assert order.sellTokenBalance == BALANCE_ERC20
            assert order.buyTokenBalance == BALANCE_ERC20
            assert self._stoploss_digest(sl) == \
                self.mock_handler.hashOrder(order, self.domain_separator), "StopLoss digest oracle mismatch"

    def _oracle(self, addr: Address) -> MockAggregatorV3:
        return next(o for o in self.oracles if o.address == addr)

    def _shed(self, who: Account | Address) -> Address:
        # Cached proxy address, so no flow needs a `proxyOf` view call.
        return self.sheds[who.address if isinstance(who, Account) else who]

    def _rpc_retry(self, thunk: Callable[[], _T]) -> _T:
        # Retries only the fork node's transient transport flake ("-32001: Unable to complete
        # request"), which it raises while fetching mainnet state on demand -- before the transaction
        # commits locally, so a retry still executes the call exactly once. Contract reverts and
        # anything else propagate unchanged.
        attempts = 6
        for i in range(attempts):
            try:
                return thunk()
            except Exception as e:  # noqa: BLE001 - re-raised unless it is the known transient flake
                msg = str(e)
                transient = isinstance(e, RuntimeError) and (
                    "-32001" in msg or "Unable to complete request" in msg
                    or "Transport error" in msg)
                if transient and i < attempts - 1:
                    logger.warning("transient fork-node RPC error, retry %d/%d: %s", i + 1, attempts, msg)
                    time.sleep(0.3 * (i + 1))
                    continue
                raise
        raise RuntimeError("unreachable")  # loop always returns or raises; keeps the type non-Optional

    def _pf(self, id: bytes32, from_):
        # pollFunds is by far the most fork-read-heavy call (singleOrders, domainSeparator, plus a
        # forked handler), so it is the one that trips the fork node's state fetch.
        return self._rpc_retry(lambda: self.poller.pollFunds(id, from_=from_))

    def _shed_exec(self, shed: Address, call: "ShedCall", from_):
        # Run a single trusted hook through a funder's CowShed. Forked bytecode, so it can hit the
        # same fork-node flake.
        payload = abi.encode_with_signature(
            "trustedExecuteHooks((address,uint256,bytes,bool,bool)[])", [call])
        return self._rpc_retry(lambda: Account(shed).transact(payload, from_=from_))

    # ------------------------------------------------------------------ helpers

    def _get_id(self, funder: Account | Address, handler: IConditionalOrderGenerator,
                owner: Account | Address, salt: bytes32) -> bytes32:
        return keccak256(abi.encode(funder, handler, owner, bytes32(salt)))

    def _params_hash(self, schedule: ComposableCowPoller.Schedule) -> bytes32:
        # paramsHash == ComposableCoW.hash(ConditionalOrderParams). Validated at setup.
        params = IConditionalOrder.ConditionalOrderParams(
            handler=schedule.handler, salt=schedule.salt, staticInput=schedule.staticInput
        )
        return keccak256(abi.encode(params))

    def _gpv2_digest(self, sell_token: Address, buy_token: Address, receiver: Address,
                     sell_amount: int, buy_amount: int, valid_to: int, app_data: bytes32,
                     fee_amount: int, kind: bytes32, partially_fillable: bool,
                     sell_token_balance: bytes32, buy_token_balance: bytes32) -> bytes32:
        # Standard GPv2 EIP-712 order digest. Validated at setup against GPv2Order.hash.
        struct_hash = keccak256(abi.encode(
            GPV2_ORDER_TYPE_HASH,
            sell_token, buy_token, receiver,
            uint256(sell_amount), uint256(buy_amount), uint256(valid_to),
            app_data, uint256(fee_amount), kind, partially_fillable,
            sell_token_balance, buy_token_balance,
        ))
        return keccak256(bytes(b"\x19\x01") + bytes(self.domain_separator) + bytes(struct_hash))

    def _order_digest(self, spec: PollerTestHandler.OrderSpec) -> bytes32:
        return self._gpv2_digest(
            spec.sellToken, spec.buyToken, spec.receiver, spec.sellAmount, spec.buyAmount,
            spec.validTo, spec.appData, spec.feeAmount, spec.kind, spec.partiallyFillable,
            spec.sellTokenBalance, spec.buyTokenBalance)

    def _valid_to_bucket(self, ts: int, validity: int) -> int:
        # Mirror of ConditionalOrdersUtilsLib.validToBucket, in uint32 arithmetic.
        ts32 = ts & 0xFFFFFFFF
        return (((ts32 // validity) * validity) + validity) & 0xFFFFFFFF

    def _tat_digest(self, tat: "TatOrder", sell_amount: int, valid_to: int) -> bytes32:
        # Full-balance market sell: buyAmount 1, fee 0, KIND_SELL, not partially fillable, ERC20
        # balances.
        return self._gpv2_digest(
            tat.sell_token, tat.buy_token, tat.receiver, sell_amount, 1, valid_to,
            tat.app_data, 0, KIND_SELL, False, BALANCE_ERC20, BALANCE_ERC20)

    # --- TWAP order model
    def _twap_valid_to(self, tw: "TwapOrder", ts: int) -> int:
        # A bundle splits into n parts of `t` seconds from `t0`, so the active index is
        # floor((ts - t0) / t) and the part runs for the whole frequency (span == 0) or `span`
        # seconds from its start. validTo is the inclusive end -- GPv2 accepts while
        # validTo >= block.timestamp, and parts must not overlap -- hence the `- 1`.
        part = (ts - tw.t0) // tw.t
        duration = tw.t if tw.span == 0 else tw.span
        return tw.t0 + part * tw.t + duration - 1

    def _twap_digest(self, tw: "TwapOrder", valid_to: int) -> bytes32:
        # sellAmount == partSellAmount, buyAmount == minPartLimit, fee 0, KIND_SELL, not partially
        # fillable, ERC20 balances.
        return self._gpv2_digest(
            tw.sell_token, tw.buy_token, tw.receiver, tw.part_sell_amount, tw.min_part_limit,
            valid_to, tw.app_data, 0, KIND_SELL, False, BALANCE_ERC20, BALANCE_ERC20)

    # --- StopLoss order model
    def _scale_price(self, price: int, from_dec: int, to_dec: int = 18) -> int:
        # Prices are normalized to 18 decimals before the strike comparison. Only ever called with
        # positive prices (the handler rejects the rest first), so floor matches Solidity's trunc.
        if from_dec < to_dec:
            return price * 10 ** (to_dec - from_dec)
        if from_dec > to_dec:
            return price // 10 ** (from_dec - to_dec)
        return price

    def _sl_triggered(self, base_answer: int, base_dec: int, quote_answer: int,
                      quote_dec: int, strike: int) -> bool:
        # Triggers iff floor(base18 * 1e18 / quote18) <= strike, sell oracle as base and buy oracle
        # as quote. `<=`, not `<`.
        base18 = self._scale_price(base_answer, base_dec)
        quote18 = self._scale_price(quote_answer, quote_dec)
        return (base18 * (10 ** 18)) // quote18 <= strike

    def _stoploss_digest(self, sl: "StopLossOrder") -> bytes32:
        # Every field is fixed by the staticInput, so the digest is constant for the schedule's
        # lifetime.
        kind = KIND_SELL if sl.is_sell_order else KIND_BUY
        return self._gpv2_digest(
            sl.sell_token, sl.buy_token, sl.receiver, sl.sell_amount, sl.buy_amount, sl.valid_to,
            sl.app_data, 0, kind, sl.is_partially_fillable, BALANCE_ERC20, BALANCE_ERC20)

    def _fund(self, token, account: Address, amount: int, minter) -> None:
        # Give `account` `amount` more of `token` (mock mint or real forked-token deal) and mirror it.
        if amount <= 0:
            return
        if isinstance(token, PollerTestToken):
            token.mint(account, amount, from_=minter)
        else:
            mint_erc20(token, account, amount)
        self.balances[token][account] += amount

    def _random_spec(self) -> PollerTestHandler.OrderSpec:
        # ~25% of the time sell a real forked token (success path); otherwise a mock token (whose
        # modes 0-3 cover the SafeERC20 result-handling edge cases).
        if random.random() < 0.25:
            sell_token = random.choice(self.real_tokens).address
        else:
            sell_token = random.choice(self.tokens).address
        return PollerTestHandler.OrderSpec(
            sellToken=sell_token,
            buyToken=random.choice(self.tokens).address,
            receiver=random_account().address if random_bool() else Address(0),
            sellAmount=random_int(0, 10 ** 24, zero_prob=0.05),
            buyAmount=random_int(0, 10 ** 24),
            validTo=random_int(0, (1 << 32) - 1),
            appData=random_bytes32(),
            feeAmount=random_int(0, 10 ** 20),
            kind=random.choice([KIND_SELL, KIND_BUY]),
            partiallyFillable=random_bool(),
            sellTokenBalance=random.choice([BALANCE_ERC20, BALANCE_EXTERNAL, BALANCE_INTERNAL]),
            buyTokenBalance=random.choice([BALANCE_ERC20, BALANCE_EXTERNAL, BALANCE_INTERNAL]),
            revertOrder=random.random() < 0.15,
        )

    def _random_mock_static(self):
        """staticInput + OrderSpec for the controllable mock handler (a fixed order). Occasionally
        returns garbage/empty (non-pollable) to keep varied paramsHash coverage."""
        if random.random() < 0.85:
            spec = self._random_spec()
            return abi.encode(spec), spec
        return random.choice([b"", random_bytes(1, 40)]), None

    def _random_tat(self):
        """staticInput + TatOrder for the real TradeAboveThreshold handler. Restricted to the
        standard / no-return sellTokens so the balance-driven transfer can actually succeed."""
        token = random.choice([self.tokens[0], self.tokens[1]])  # mode 0/1 only
        tat = TatOrder(
            sell_token=token.address,
            buy_token=random.choice(self.tokens).address,
            receiver=random_account().address if random_bool() else Address(0),
            validity=random_int(300, 86400),
            threshold=random_int(0, 10 ** 21, zero_prob=0.1),
            app_data=random_bytes32(),
        )
        data = TradeAboveThreshold.Data(
            sellToken=IERC20(tat.sell_token), buyToken=IERC20(tat.buy_token), receiver=tat.receiver,
            validityBucketSeconds=uint32(tat.validity), threshold=uint256(tat.threshold),
            appData=tat.app_data)
        return abi.encode(data), tat

    def _fundable_sell_token(self) -> Address:
        """A sellToken whose transferFrom succeeds: mock mode 0/1, or a real ERC20. Modes 2/3 are
        left to the mock-handler path, which drives the SafeERC20 failure edges deterministically."""
        if random.random() < 0.3:
            return random.choice(self.real_tokens).address
        return random.choice([self.tokens[0], self.tokens[1]]).address

    def _random_twap(self, force_live: bool = False):
        """staticInput + TwapOrder for the real forked TWAP handler. Always builds a *valid* bundle
        (so the handler never reverts on validation) with a concrete t0. When force_live is set, t0 is
        in the past and span==0 so the bundle is guaranteed to be within a live part right now."""
        now = chain.blocks["latest"].timestamp
        n = random_int(2, 6)
        t = random_int(300, 86400)
        span = 0 if (force_live or random_bool()) else random_int(1, t)
        if not force_live and random.random() < 0.12:
            t0 = now + random_int(1, 2 * t)          # future start => BEFORE_TWAP_START coverage
        else:
            t0 = max(0, now - random_int(0, (n - 1) * t))
        sell = self._fundable_sell_token()
        buy = random.choice(self.tokens).address
        while buy == sell:
            buy = random.choice(self.tokens).address
        receiver = random_account().address if random_bool() else Address(0)
        app_data = random_bytes32()
        tw = TwapOrder(
            sell_token=sell, buy_token=buy, receiver=receiver,
            part_sell_amount=random_int(1, 10 ** 21), min_part_limit=random_int(1, 10 ** 21),
            t0=t0, n=n, t=t, span=span, app_data=app_data)
        data = TWAPOrder.Data(
            sellToken=IERC20(sell), buyToken=IERC20(buy), receiver=receiver,
            partSellAmount=uint256(tw.part_sell_amount), minPartLimit=uint256(tw.min_part_limit),
            t0=uint256(t0), n=uint256(n), t=uint256(t), span=uint256(span), appData=app_data)
        return abi.encode(data), tw

    def _random_stoploss(self, force_success: bool = False):
        """staticInput + StopLossOrder for the real forked StopLoss handler. Two distinct mock
        oracles are assigned; their answers/staleness are set at poll time, not here. `validTo` is
        sometimes near `now` so it can naturally expire as the fuzzer mines forward."""
        now = chain.blocks["latest"].timestamp
        sell = self._fundable_sell_token()
        buy = random.choice(self.tokens).address
        while buy == sell:
            buy = random.choice(self.tokens).address
        o_sell, o_buy = random.sample(self.oracles, 2)
        if force_success:
            valid_to = min((1 << 32) - 1, now + 10 * 86400)
        else:
            valid_to = min((1 << 32) - 1, now + random_int(0, 3 * 86400))
        sl = StopLossOrder(
            sell_token=sell, buy_token=buy,
            sell_amount=random_int(0, 10 ** 21, zero_prob=0.05), buy_amount=random_int(0, 10 ** 21),
            app_data=random_bytes32(),
            receiver=random_account().address if random_bool() else Address(0),
            is_sell_order=random_bool(), is_partially_fillable=random_bool(),
            valid_to=valid_to, sell_oracle=o_sell.address, buy_oracle=o_buy.address,
            sell_dec=self.oracle_dec[o_sell.address], buy_dec=self.oracle_dec[o_buy.address],
            strike=random_int(1, 10 ** 24), max_stale=random_int(300, 86400))
        data = StopLoss.Data(
            sellToken=IERC20(sell), buyToken=IERC20(buy), sellAmount=uint256(sl.sell_amount),
            buyAmount=uint256(sl.buy_amount), appData=sl.app_data, receiver=sl.receiver,
            isSellOrder=sl.is_sell_order, isPartiallyFillable=sl.is_partially_fillable,
            validTo=uint32(valid_to), sellTokenPriceOracle=IAggregatorV3Interface(o_sell.address),
            buyTokenPriceOracle=IAggregatorV3Interface(o_buy.address), strike=sl.strike,
            maxTimeSinceLastOracleUpdate=uint256(sl.max_stale))
        return abi.encode(data), sl

    def _random_schedule(self):
        r = random.random()
        if r < 0.34:
            handler = self.mock_handler
            static_input, order_obj = self._random_mock_static()
        elif r < 0.54:
            handler = TWAP_HANDLER                      # end-to-end
            static_input, order_obj = self._random_twap()
        elif r < 0.74:
            handler = STOP_LOSS_HANDLER                 # end-to-end
            static_input, order_obj = self._random_stoploss()
        elif r < 0.86:
            handler = TRADE_ABOVE_THRESHOLD
            static_input, order_obj = self._random_tat()
        else:
            handler = random.choice(REAL_HANDLERS)
            static_input, order_obj = random.choice([b"", random_bytes(0, 40)]), None
        funder = random_account()
        owner = random_account()
        salt = random.choice(SALTS)
        id = self._get_id(funder, handler, owner, salt)
        schedule = ComposableCowPoller.Schedule(
            handler=handler,
            authEpoch=uint96(self.auth_epochs[id]),
            funder=funder.address,
            owner=owner.address,
            salt=salt,
            staticInput=static_input,
        )
        return id, schedule, order_obj

    def _register_effect(self, id: bytes32, schedule: ComposableCowPoller.Schedule,
                         spec: PollerTestHandler.OrderSpec | TatOrder | TwapOrder | StopLossOrder | None,
                         tx) -> None:
        # Independently recomputed params hash; the contract must emit exactly this.
        params_hash = self._params_hash(schedule)
        assert ComposableCowPoller.ScheduleRegistered(
            id=id,
            owner=schedule.owner,
            funder=schedule.funder,
            authEpoch=schedule.authEpoch,
            paramsHash=params_hash,
        ) in tx.events
        self.schedules[id] = schedule
        self.order_specs[id] = spec
        self.all_ids.add(id)

    def _revoke_effect(self, id: bytes32, schedule: ComposableCowPoller.Schedule, tx) -> None:
        assert ComposableCowPoller.ScheduleRevoked(
            id=id, owner=schedule.owner, funder=schedule.funder
        ) in tx.events
        del self.schedules[id]
        self.order_specs.pop(id, None)
        self.auth_epochs[id] += 1
        self.all_ids.add(id)
        # self.funded[id] is deliberately left alone -- funding history survives revocation.

    def _pollable_ids(self) -> list:
        return [i for i in self.schedules if self.order_specs.get(i) is not None]

    def _fresh_unregistered_id(self) -> bytes32:
        while True:
            id = random_bytes32()
            if id not in self.schedules:
                return id

    # ------------------------------------------------------------------ register flows

    @flow(weight=120)
    def flow_register(self) -> str | None:
        id, schedule, spec = self._random_schedule()

        with may_revert() as ex:
            tx = self.poller.register(schedule=schedule, from_=schedule.funder)

        if id in self.schedules:
            assert ex.value == ComposableCowPoller.AlreadyRegistered()
            return "Already registered"
        assert ex.value is None
        self._register_effect(id, schedule, spec, tx)

    @flow(weight=40)
    def flow_register_wrong_caller(self) -> str | None:
        # OnlyFunder: register must revert when msg.sender != funder.
        id, schedule, _ = self._random_schedule()
        caller = random_account()
        while caller.address == schedule.funder:
            caller = random_account()
        with may_revert() as ex:
            self.poller.register(schedule=schedule, from_=caller)
        # OnlyFunder is checked before the AlreadyRegistered / InvalidAuthEpoch checks.
        assert ex.value == ComposableCowPoller.OnlyFunder()
        return "OnlyFunder"

    @flow(weight=30)
    def flow_register_wrong_epoch(self) -> str | None:
        # InvalidAuthEpoch: supply an epoch that does not match storage for an inactive id.
        id, schedule, _ = self._random_schedule()
        if id in self.schedules:
            return "active id"
        stored = self.auth_epochs[id]
        wrong = stored + random_int(1, 5) if random_bool() or stored == 0 else stored - 1
        schedule = dataclasses.replace(schedule, authEpoch=uint96(wrong))
        with may_revert() as ex:
            self.poller.register(schedule=schedule, from_=schedule.funder)
        assert ex.value == ComposableCowPoller.InvalidAuthEpoch()
        return "InvalidAuthEpoch"

    @flow(weight=70)
    def flow_register_with_signature(self) -> str | None:
        id, schedule, spec = self._random_schedule()
        deadline = chain.blocks["latest"].timestamp + random_int(1, 1000)

        registration = ScheduleRegistration(
            handler=schedule.handler.address,
            authEpoch=schedule.authEpoch,
            funder=schedule.funder,
            owner=schedule.owner,
            salt=schedule.salt,
            staticInput=schedule.staticInput,
            deadline=deadline,
        )
        with may_revert() as ex:
            tx = self.poller.registerWithSignature(
                schedule, deadline,
                Account(schedule.funder).sign_structured(registration, self._domain()),
                from_=random_account(),
            )
        if id in self.schedules:
            assert ex.value == ComposableCowPoller.AlreadyRegistered()
            return "Already registered"
        assert ex.value is None
        self._register_effect(id, schedule, spec, tx)

    @flow(weight=40)
    def flow_register_with_signature_bad(self) -> str | None:
        # SignatureExpired (past deadline) and InvalidSignature (wrong signer OR malformed signature).
        id, schedule, _ = self._random_schedule()
        kind = random.choice(["expired", "wrong_signer", "malformed"])
        if kind == "expired":
            deadline = chain.blocks["latest"].timestamp - random_int(0, 10)
        else:
            deadline = chain.blocks["latest"].timestamp + random_int(1, 1000)

        registration = ScheduleRegistration(
            handler=schedule.handler.address, authEpoch=schedule.authEpoch, funder=schedule.funder,
            owner=schedule.owner, salt=schedule.salt, staticInput=schedule.staticInput, deadline=deadline,
        )
        if kind == "malformed":
            # A garbage signature of invalid length: ECDSA.tryRecover fails and an EOA funder has no
            # ERC-1271 magic to offer, so SignatureChecker returns false -> InvalidSignature.
            signature = random.choice([b"", random_bytes(66, 130)])
        else:
            signer = Account(schedule.funder)
            if kind == "wrong_signer":
                other = random_account()
                while other.address == schedule.funder:
                    other = random_account()
                signer = other
            signature = signer.sign_structured(registration, self._domain())
        with may_revert() as ex:
            self.poller.registerWithSignature(schedule, deadline, signature, from_=random_account())
        if kind == "expired":
            assert ex.value == ComposableCowPoller.SignatureExpired()
            return "SignatureExpired"
        # Deadline is in the future; signature check runs and fails.
        assert ex.value == ComposableCowPoller.InvalidSignature()
        return f"InvalidSignature ({kind})"

    @flow(weight=40)
    def flow_register_from_shed(self) -> str | None:
        _, base, _ = self._random_schedule()
        funder = base.funder
        owner = self._shed(funder)
        salt = base.salt
        handler = base.handler
        static_input = random.choice([b"", random_bytes(1, 40)])  # shed-owned => not pollable

        id = self._get_id(Account(funder), handler, Account(owner), salt)
        schedule = ComposableCowPoller.Schedule(
            handler=handler, authEpoch=uint96(self.auth_epochs[id]), funder=funder,
            owner=owner, salt=salt, staticInput=static_input,
        )
        call = ShedCall(
            target=self.poller.address, value=0,
            callData=abi.encode_call(self.poller.registerFromShed, [schedule]),
            allowFailure=False, isDelegatecall=False,
        )
        with may_revert() as ex:
            tx = self._shed_exec(owner, call, funder)
        if id in self.schedules:
            # The pinned CowShed bubbles the inner revert data verbatim.
            assert ex.value == ComposableCowPoller.AlreadyRegistered()
            return "Already registered"
        assert ex.value is None
        self._register_effect(id, schedule, None, tx)

    # ------------------------------------------------------------------ revoke flows

    @flow(weight=45)
    def flow_revoke(self) -> str | None:
        if not self.schedules:
            return "No schedules to revoke"
        id = random.choice(list(self.schedules.keys()))
        schedule = self.schedules[id]
        tx = self.poller.revoke(
            handler=schedule.handler, owner=schedule.owner, salt=schedule.salt, from_=schedule.funder
        )
        self._revoke_effect(id, schedule, tx)

    @flow(weight=35)
    def flow_revoke_with_signature(self) -> str | None:
        if not self.schedules:
            return "No schedules to revoke"
        id = random.choice(list(self.schedules.keys()))
        schedule = self.schedules[id]
        deadline = chain.blocks["latest"].timestamp + random_int(1, 1000)
        revoke = Revoke(
            handler=schedule.handler.address, authEpoch=schedule.authEpoch, funder=schedule.funder,
            owner=schedule.owner, salt=schedule.salt, deadline=deadline,
        )
        tx = self.poller.revokeWithSignature(
            handler=schedule.handler, funder=schedule.funder, owner=schedule.owner, salt=schedule.salt,
            authEpoch=schedule.authEpoch, deadline=deadline,
            signature=Account(schedule.funder).sign_structured(revoke, self._domain()),
            from_=random_account(),
        )
        self._revoke_effect(id, schedule, tx)

    @flow(weight=25)
    def flow_revoke_preemptive_direct(self) -> str | None:
        # Pre-emptive cancel through the direct revoke() / revokeWithSignature() entrypoints, on an id
        # that is not currently registered: a funder bumps authEpoch to kill a leaked or pending
        # signed registration before it can ever be used. Must emit ScheduleRevoked and bump the
        # epoch, after which a registration signed at the stale epoch is rejected.
        handler = self.mock_handler if random_bool() else random.choice(REAL_HANDLERS)
        funder = random_account()
        owner = random_account()
        salt = random.choice(SALTS)
        id = self._get_id(funder, handler, owner, salt)
        if id in self.schedules:
            return "id is registered"  # active ids are covered by flow_revoke / _with_signature
        stored = self.auth_epochs[id]
        use_sig = random_bool()

        if use_sig:
            deadline = chain.blocks["latest"].timestamp + random_int(1, 1000)
            revoke = Revoke(
                handler=handler.address, authEpoch=uint96(stored), funder=funder.address,
                owner=owner.address, salt=salt, deadline=deadline)
            tx = self.poller.revokeWithSignature(
                handler=handler, funder=funder.address, owner=owner.address, salt=salt,
                authEpoch=uint96(stored), deadline=deadline,
                signature=funder.sign_structured(revoke, self._domain()), from_=random_account())
        else:
            tx = self.poller.revoke(handler=handler, owner=owner.address, salt=salt, from_=funder)

        assert ComposableCowPoller.ScheduleRevoked(
            id=id, owner=owner.address, funder=funder.address) in tx.events
        self.auth_epochs[id] += 1
        self.all_ids.add(id)

        # A registration signed at the now-stale epoch must revert InvalidAuthEpoch. The signature
        # itself is valid, so this pins the rejection on the epoch bump. staticInput is irrelevant --
        # registration reverts before storing anything.
        deadline2 = chain.blocks["latest"].timestamp + 1000
        schedule_old = ComposableCowPoller.Schedule(
            handler=handler, authEpoch=uint96(stored), funder=funder.address, owner=owner.address,
            salt=salt, staticInput=b"")
        reg = ScheduleRegistration(
            handler=handler.address, authEpoch=uint96(stored), funder=funder.address,
            owner=owner.address, salt=salt, staticInput=b"", deadline=deadline2)
        with may_revert() as ex:
            self.poller.registerWithSignature(
                schedule_old, deadline2, funder.sign_structured(reg, self._domain()),
                from_=random_account())
        assert ex.value == ComposableCowPoller.InvalidAuthEpoch()
        return f"preemptive direct revoke ({'sig' if use_sig else 'direct'})"

    @flow(weight=15)
    def flow_erc1271_signature(self) -> str | None:
        # Contract-funder path: SignatureChecker forwards the EIP-712 digest to a funder that has
        # code and wants the 0x1626ba7e magic value back. The wallet recovers the signer from the
        # digest it is handed, so this also pins down that the poller presents the right one.
        # Registers and revokes in one go -- a contract-funded schedule left behind would break the
        # general flows, which originate transactions from the funder.
        wallet = random.choice(self.erc1271_wallets)
        owner_eoa = self.wallet_owner[wallet.address]
        handler = self.mock_handler if random_bool() else random.choice(REAL_HANDLERS)
        owner = random_account()
        salt = random.choice(SALTS)
        id = self._get_id(wallet, handler, owner, salt)
        if id in self.schedules:
            return "id busy"
        static = random.choice([b"", random_bytes(1, 40)])
        stored = self.auth_epochs[id]

        other = random_account()
        while other.address == owner_eoa.address:
            other = random_account()

        schedule = ComposableCowPoller.Schedule(
            handler=handler, authEpoch=uint96(stored), funder=wallet.address, owner=owner.address,
            salt=salt, staticInput=static)
        # One signed deadline, two transactions: the failure attempt below mines a block before the
        # success, so keep the deadline far enough out that the second one cannot expire on timing
        # alone.
        deadline = chain.blocks["latest"].timestamp + random_int(3600, 7200)
        reg = ScheduleRegistration(
            handler=handler.address, authEpoch=uint96(stored), funder=wallet.address,
            owner=owner.address, salt=salt, staticInput=static, deadline=deadline)

        # register failure: a valid signature from the wrong EOA (wallet recovers a non-owner) or a
        # malformed one (wallet's length != 65 guard). Both give a non-magic return.
        if random_bool():
            bad_sig = other.sign_structured(reg, self._domain())
        else:
            bad_sig = random.choice([b"", random_bytes(66, 130)])
        with may_revert() as ex:
            self.poller.registerWithSignature(
                schedule, deadline, bad_sig, from_=random_account())
        assert ex.value == ComposableCowPoller.InvalidSignature()

        # register success: the owner EOA authorizes via the wallet's ERC-1271 isValidSignature.
        tx = self.poller.registerWithSignature(
            schedule, deadline, owner_eoa.sign_structured(reg, self._domain()), from_=random_account())
        self._register_effect(id, schedule, None, tx)

        rdeadline = chain.blocks["latest"].timestamp + random_int(3600, 7200)  # future for both txs
        rev = Revoke(
            handler=handler.address, authEpoch=uint96(stored), funder=wallet.address,
            owner=owner.address, salt=salt, deadline=rdeadline)

        # revoke failure: wrong signer -> InvalidSignature; the schedule stays registered.
        with may_revert() as ex:
            self.poller.revokeWithSignature(
                handler=handler, funder=wallet.address, owner=owner.address, salt=salt,
                authEpoch=uint96(stored), deadline=rdeadline,
                signature=other.sign_structured(rev, self._domain()), from_=random_account())
        assert ex.value == ComposableCowPoller.InvalidSignature()

        # revoke success: owner EOA authorizes -> schedule revoked, epoch bumped.
        tx = self.poller.revokeWithSignature(
            handler=handler, funder=wallet.address, owner=owner.address, salt=salt,
            authEpoch=uint96(stored), deadline=rdeadline,
            signature=owner_eoa.sign_structured(rev, self._domain()), from_=random_account())
        self._revoke_effect(id, schedule, tx)
        return None

    @flow(weight=35)
    def flow_revoke_with_signature_bad(self) -> str | None:
        if not self.schedules:
            return "No schedules to revoke"
        id = random.choice(list(self.schedules.keys()))
        schedule = self.schedules[id]
        kind = random.choice(["expired", "epoch", "signer", "malformed"])

        if kind == "expired":
            deadline = chain.blocks["latest"].timestamp - random_int(0, 10)
        else:
            deadline = chain.blocks["latest"].timestamp + random_int(1, 1000)
        auth_epoch = schedule.authEpoch
        if kind == "epoch":
            auth_epoch = uint96(schedule.authEpoch + random_int(1, 5))

        revoke = Revoke(
            handler=schedule.handler.address, authEpoch=auth_epoch, funder=schedule.funder,
            owner=schedule.owner, salt=schedule.salt, deadline=deadline,
        )
        if kind == "malformed":
            # Correct deadline + epoch, but a garbage signature of invalid length -> InvalidSignature.
            signature = random.choice([b"", random_bytes(66, 130)])
        else:
            signer = Account(schedule.funder)
            if kind == "signer":
                other = random_account()
                while other.address == schedule.funder:
                    other = random_account()
                signer = other
            signature = signer.sign_structured(revoke, self._domain())

        with may_revert() as ex:
            self.poller.revokeWithSignature(
                handler=schedule.handler, funder=schedule.funder, owner=schedule.owner, salt=schedule.salt,
                authEpoch=auth_epoch, deadline=deadline, signature=signature, from_=random_account(),
            )
        if kind == "expired":
            assert ex.value == ComposableCowPoller.SignatureExpired()
        elif kind == "epoch":
            # InvalidAuthEpoch is checked before the signature.
            assert ex.value == ComposableCowPoller.InvalidAuthEpoch()
        else:  # wrong signer OR malformed signature
            assert ex.value == ComposableCowPoller.InvalidSignature()
        return f"revoke-sig bad: {kind}"

    @flow(weight=35)
    def flow_revoke_from_shed(self) -> str | None:
        if not self.schedules:
            return "No schedules to revoke"
        id = random.choice(list(self.schedules.keys()))
        schedule = self.schedules[id]
        call = ShedCall(
            target=self.poller.address, value=0,
            callData=abi.encode_call(self.poller.revokeFromShed, [
                schedule.handler, schedule.funder, schedule.owner, schedule.salt, schedule.authEpoch,
            ]),
            allowFailure=False, isDelegatecall=False,
        )
        shed = self._shed(schedule.funder)
        with may_revert() as ex:
            tx = self._shed_exec(shed, call, schedule.funder)
        assert ex.value is None
        self._revoke_effect(id, schedule, tx)

    # ------------------------------------------------------------------ shed-authorization negatives

    @flow(weight=35)
    def flow_register_from_shed_unauthorized(self) -> str | None:
        # Every path here must revert `UnauthorizedShed`; state is never mutated.
        handler = self.mock_handler if random_bool() else random.choice(REAL_HANDLERS)
        funder = random_account()
        salt = random.choice(SALTS)
        scenario = random.choice(["direct_eoa", "zero_funder", "other_shed", "wrong_owner"])

        if scenario == "direct_eoa":
            # A plain EOA (never a shed) calls registerFromShed => msg.sender != proxyOf(funder).
            schedule = ComposableCowPoller.Schedule(
                handler=handler, authEpoch=uint96(0), funder=funder.address,
                owner=random_account().address, salt=salt, staticInput=b"")
            with may_revert() as ex:
                self.poller.registerFromShed(schedule, from_=random_account())
            assert ex.value == ComposableCowPoller.UnauthorizedShed()
            return "reg-from-shed unauthorized: direct_eoa"

        if scenario == "zero_funder":
            # funder == address(0) short-circuits _requireFunderShed regardless of caller.
            schedule = ComposableCowPoller.Schedule(
                handler=handler, authEpoch=uint96(0), funder=Address(0),
                owner=random_account().address, salt=salt, staticInput=b"")
            with may_revert() as ex:
                self.poller.registerFromShed(schedule, from_=random_account())
            assert ex.value == ComposableCowPoller.UnauthorizedShed()
            return "reg-from-shed unauthorized: zero_funder"

        if scenario == "other_shed":
            # Another user's shed calls registerFromShed for `funder` => proxyOf(other) != proxyOf(funder).
            other = random_account()
            while other.address == funder.address:
                other = random_account()
            schedule = ComposableCowPoller.Schedule(
                handler=handler, authEpoch=uint96(0), funder=funder.address,
                owner=random_account().address, salt=salt, staticInput=b"")
            call = ShedCall(
                target=self.poller.address, value=0,
                callData=abi.encode_call(self.poller.registerFromShed, [schedule]),
                allowFailure=False, isDelegatecall=False)
            with may_revert() as ex:
                self._shed_exec(self._shed(other), call, other)
            assert ex.value == ComposableCowPoller.UnauthorizedShed()
            return "reg-from-shed unauthorized: other_shed"

        # wrong_owner: funder's own shed calls, but schedule.owner != the calling shed.
        shed = self._shed(funder)
        wrong_owner = random_account().address
        while wrong_owner == shed:
            wrong_owner = random_account().address
        schedule = ComposableCowPoller.Schedule(
            handler=handler, authEpoch=uint96(0), funder=funder.address,
            owner=wrong_owner, salt=salt, staticInput=b"")
        call = ShedCall(
            target=self.poller.address, value=0,
            callData=abi.encode_call(self.poller.registerFromShed, [schedule]),
            allowFailure=False, isDelegatecall=False)
        with may_revert() as ex:
            self._shed_exec(shed, call, funder)
        assert ex.value == ComposableCowPoller.UnauthorizedShed()
        return "reg-from-shed unauthorized: wrong_owner"

    @flow(weight=35)
    def flow_revoke_from_shed_bad(self) -> str | None:
        handler = self.mock_handler if random_bool() else random.choice(REAL_HANDLERS)
        funder = random_account()
        owner = random_account().address
        salt = random.choice(SALTS)
        scenario = random.choice(["direct_eoa", "zero_funder", "other_shed", "wrong_epoch"])

        if scenario == "direct_eoa":
            with may_revert() as ex:
                self.poller.revokeFromShed(handler, funder.address, owner, salt, uint96(0), from_=random_account())
            assert ex.value == ComposableCowPoller.UnauthorizedShed()
            return "revoke-from-shed unauthorized: direct_eoa"

        if scenario == "zero_funder":
            with may_revert() as ex:
                self.poller.revokeFromShed(handler, Address(0), owner, salt, uint96(0), from_=random_account())
            assert ex.value == ComposableCowPoller.UnauthorizedShed()
            return "revoke-from-shed unauthorized: zero_funder"

        if scenario == "other_shed":
            other = random_account()
            while other.address == funder.address:
                other = random_account()
            call = ShedCall(
                target=self.poller.address, value=0,
                callData=abi.encode_call(self.poller.revokeFromShed, [handler, funder.address, owner, salt, uint96(0)]),
                allowFailure=False, isDelegatecall=False)
            with may_revert() as ex:
                self._shed_exec(self._shed(other), call, other)
            assert ex.value == ComposableCowPoller.UnauthorizedShed()
            return "revoke-from-shed unauthorized: other_shed"

        # wrong_epoch: funder's shed calls with an authEpoch that does not match storage.
        id = self._get_id(funder, handler, Account(owner), salt)
        wrong = self.auth_epochs[id] + random_int(1, 5)
        call = ShedCall(
            target=self.poller.address, value=0,
            callData=abi.encode_call(self.poller.revokeFromShed, [handler, funder.address, owner, salt, uint96(wrong)]),
            allowFailure=False, isDelegatecall=False)
        with may_revert() as ex:
            self._shed_exec(self._shed(funder), call, funder)
        assert ex.value == ComposableCowPoller.InvalidAuthEpoch()
        return "revoke-from-shed: wrong_epoch"

    @flow(weight=25)
    def flow_revoke_from_shed_preemptive(self) -> str | None:
        # Pre-emptive cancel: a funder's shed revokes an id that is not currently registered, at its
        # current epoch. This must succeed and bump the epoch (invalidating any pending signed
        # registration for that id), even though there is no active schedule to delete.
        handler = self.mock_handler if random_bool() else random.choice(REAL_HANDLERS)
        funder = random_account()
        owner = random_account()
        salt = random.choice(SALTS)
        id = self._get_id(funder, handler, owner, salt)
        if id in self.schedules:
            return "id is registered"  # covered by flow_revoke_from_shed
        stored = self.auth_epochs[id]
        call = ShedCall(
            target=self.poller.address, value=0,
            callData=abi.encode_call(self.poller.revokeFromShed,
                                     [handler, funder.address, owner.address, salt, uint96(stored)]),
            allowFailure=False, isDelegatecall=False)
        tx = self._shed_exec(self._shed(funder), call, funder)
        assert ComposableCowPoller.ScheduleRevoked(
            id=id, owner=owner.address, funder=funder.address) in tx.events
        self.auth_epochs[id] += 1
        self.all_ids.add(id)

    # ------------------------------------------------------------------ order authorization flows

    @flow(weight=110)
    def flow_create_order(self) -> str | None:
        ids = self._pollable_ids()
        if not ids:
            return "no pollable schedules"
        id = random.choice(ids)
        schedule = self.schedules[id]
        params = IConditionalOrder.ConditionalOrderParams(
            handler=schedule.handler, salt=schedule.salt, staticInput=schedule.staticInput
        )
        params_hash = keccak256(abi.encode(params))
        dispatch = random_bool()
        # Authorizes the order in ComposableCoW; setup for pollFunds. Its ConditionalOrderCreated
        # event is not asserted -- ComposableCoW is forked without a pytypes_resolver, so Wake
        # surfaces its logs as untyped ExternalEvent. `dispatch` is randomized to hit both branches.
        self._rpc_retry(lambda: COMPOSABLE_COW.create(params, dispatch, from_=Account(schedule.owner)))
        self.created.add((schedule.owner, params_hash))
        self.all_created_pairs.add((schedule.owner, params_hash))

    @flow(weight=30)
    def flow_remove_order(self) -> str | None:
        if not self.created:
            return "nothing created"
        owner_addr, params_hash = random.choice(list(self.created))
        self._rpc_retry(lambda: COMPOSABLE_COW.remove(params_hash, from_=Account(owner_addr)))
        self.created.discard((owner_addr, params_hash))

    # ------------------------------------------------------------------ pollFunds

    @flow(weight=170)
    def flow_poll_funds(self) -> str | None:
        caller = random_account()

        # NoSchedule: an id that was never registered (or has been revoked).
        if random.random() < 0.1 or not self._pollable_ids():
            id = self._fresh_unregistered_id()
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == ComposableCowPoller.NoSchedule()
            return "NoSchedule"

        id = random.choice(self._pollable_ids())
        schedule = self.schedules[id]
        order_obj = self.order_specs[id]
        assert order_obj is not None
        params_hash = self._params_hash(schedule)
        owner_addr = schedule.owner
        funder_addr = schedule.funder

        # OrderNotLive: the order is not authorised in ComposableCoW.
        if (owner_addr, params_hash) not in self.created:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == ComposableCowPoller.OrderNotLive()
            return "OrderNotLive"

        # Real TradeAboveThreshold handler: balance-driven order, handled separately.
        if isinstance(order_obj, TatOrder):
            return self._poll_tat(id, order_obj, owner_addr, funder_addr, caller)

        # Real forked TWAP handler: fixed part sellAmount, per-part validTo.
        if isinstance(order_obj, TwapOrder):
            return self._poll_twap(id, order_obj, owner_addr, funder_addr, caller)

        # Real forked StopLoss handler: fixed order, oracle-gated.
        if isinstance(order_obj, StopLossOrder):
            return self._poll_stoploss(id, order_obj, owner_addr, funder_addr, caller)

        spec = order_obj  # PollerTestHandler.OrderSpec (fixed mock order)
        token = self.token_by_addr[spec.sellToken]
        is_real = spec.sellToken in self.real_token_addrs

        # Handler reverts inside its window: the revert must propagate out of pollFunds.
        if spec.revertOrder:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.OrderNotValid("poller-test: not live")
            return "handler revert"

        digest = self._order_digest(spec)

        # Already funded: returns false and moves nothing, even for the revert-mode tokens (the
        # funded check happens before the transfer).
        if digest in self.funded[id]:
            tx = self._pf(id, caller)
            assert tx.return_value is False
            assert not any(isinstance(e, ComposableCowPoller.Pulled) for e in tx.events)
            return "already funded"

        need = spec.sellAmount

        # Real ERC20 sellToken: the SafeERC20 success path against production bytecode, USDT's
        # missing bool return included. Funded with mint_erc20, relying on the pre_sequence approval.
        # The failure edges stay on the mock tokens, which reproduce them deterministically.
        if is_real:
            have = self.balances[token][funder_addr]
            if have < need:
                mint_erc20(token, funder_addr, need - have)
                self.balances[token][funder_addr] += need - have
            tx = self._pf(id, caller)
            assert tx.return_value is True
            assert ComposableCowPoller.Pulled(id=id, orderDigest=digest, amount=need) in tx.events
            self.balances[token][funder_addr] -= need
            self.balances[token][owner_addr] += need
            self.funded[id].add(digest)
            return None

        assert isinstance(token, PollerTestToken)  # mock token from here on
        mode = self.token_mode[spec.sellToken]

        # Fresh digest with a token whose transferFrom reports failure: SafeERC20 must revert and
        # nothing (not even `funded`) may persist.
        if mode == 2:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == Error("GPv2: failed transferFrom")
            return "safe-transfer false"
        if mode == 3:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == Error("GPv2: malformed transfer result")
            return "safe-transfer malformed"

        have = self.balances[token][funder_addr]
        reverted = None  # description of a deliberate pre-transfer revert, if any

        # Under-approved funder: every poll for the schedule reverts. Fund it first so the revert is
        # specifically about the allowance, then restore the approval before recovering below.
        if need > 0 and random.random() < 0.15:
            if have < need:
                token.mint(funder_addr, need - have, from_=caller)
                self.balances[token][funder_addr] += need - have
                have = need
            token.approve(self.poller, need - 1, from_=funder_addr)
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == Error("MOCK20: allowance")
            token.approve(self.poller, MAX_UINT, from_=funder_addr)  # restore infinite approval
            reverted = "insufficient allowance"

        # Funder is short. There is no balance precheck, so the ERC20 transfer itself reverts.
        elif need > have and random.random() < 0.35:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == Error("MOCK20: balance")
            reverted = "insufficient balance"

        # Success poll. Coming after one of the deliberate reverts above, it also shows the
        # pre-transfer `funded[id][digest] = true` write was rolled back: a stuck flag would return
        # false here instead of funding.
        have = self.balances[token][funder_addr]
        if have < need:
            token.mint(funder_addr, need - have, from_=caller)
            self.balances[token][funder_addr] += need - have

        tx = self._pf(id, caller)
        assert tx.return_value is True
        assert ComposableCowPoller.Pulled(id=id, orderDigest=digest, amount=need) in tx.events
        # Exactly `need` of the sellToken moves from funder to owner.
        self.balances[token][funder_addr] -= need
        self.balances[token][owner_addr] += need
        self.funded[id].add(digest)
        return f"funded after {reverted}" if reverted else None

    def _poll_tat(self, id: bytes32, tat: TatOrder, owner_addr: Address,
                  funder_addr: Address, caller) -> str | None:
        # TradeAboveThreshold sells the owner's whole sellToken balance once it reaches the
        # threshold, else the handler reverts PollTryNextBlock. validTo is bucketed by `validity`, so
        # the digest moves with the bucket and with the balance.
        token = self.token_by_addr[tat.sell_token]
        assert isinstance(token, PollerTestToken)  # TAT sellTokens are mock tokens only
        owner_balance = self.balances[token][owner_addr]

        # Sometimes top the owner up over the threshold to reach the live path.
        if owner_balance < tat.threshold and random.random() < 0.6:
            topup = tat.threshold - owner_balance + random_int(0, 10 ** 18)
            token.mint(owner_addr, topup, from_=caller)
            self.balances[token][owner_addr] += topup
            owner_balance += topup

        # Below threshold: getTradeableOrder reverts PollTryNextBlock, propagated by pollFunds.
        if owner_balance < tat.threshold:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.PollTryNextBlock(TAT_BALANCE_INSUFFICIENT)
            return "TAT below threshold"

        need = owner_balance  # the handler sells the owner's whole balance

        # Deliberately underfund the funder sometimes (only meaningful when funder != owner).
        funder_have = self.balances[token][funder_addr]
        if funder_have < need and random.random() < 0.3:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == Error("MOCK20: balance")
            return "TAT insufficient balance"
        if funder_have < need:
            token.mint(funder_addr, need - funder_have, from_=caller)
            self.balances[token][funder_addr] += need - funder_have

        tx = self._pf(id, caller)
        valid_to = self._valid_to_bucket(tx.block.timestamp, tat.validity)
        digest = self._tat_digest(tat, need, valid_to)
        if digest in self.funded[id]:
            assert tx.return_value is False
            assert not any(isinstance(e, ComposableCowPoller.Pulled) for e in tx.events)
        else:
            assert tx.return_value is True
            assert ComposableCowPoller.Pulled(id=id, orderDigest=digest, amount=need) in tx.events
            self.balances[token][funder_addr] -= need
            self.balances[token][owner_addr] += need
            self.funded[id].add(digest)
        return None

    # Seconds of slack around every timing boundary, comfortably more than the handful of setup
    # transactions that can run between reading the timestamp and the poll, so drift cannot flip the
    # expected branch. Inside the margin the flow skips instead.
    _TIMING_MARGIN = 30

    def _poll_twap(self, id: bytes32, tw: TwapOrder, owner_addr: Address,
                   funder_addr: Address, caller) -> str | None:
        # Each poll funds exactly `partSellAmount` for the live part, and the order's validTo is the
        # inclusive end of that part, so the digest changes from part to part. Outside a live part
        # the handler refuses and pollFunds propagates the revert.
        token = self.token_by_addr[tw.sell_token]
        M = self._TIMING_MARGIN
        # `latest` timestamp; the poll block is a few seconds later (<= M), which the margins absorb.
        now = chain.blocks["latest"].timestamp
        finish = tw.t0 + tw.n * tw.t

        # Before the bundle's start (only reachable via a future-t0 bundle): OrderNotValid.
        if now < tw.t0 - M:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.OrderNotValid(TWAP_BEFORE_START)
            return "twap before start"
        # Past the final part: OrderNotValid.
        if now >= finish + M:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.OrderNotValid(TWAP_AFTER_FINISH)
            return "twap after finish"
        # Near the start/finish edge: skip rather than risk a drift-induced misclassification.
        if now < tw.t0 + M or now > finish - M:
            return "twap near lifetime boundary"

        part = (now - tw.t0) // tw.t
        part_start = tw.t0 + part * tw.t
        duration = tw.t if tw.span == 0 else tw.span
        valid_to = part_start + duration - 1

        if tw.span > 0:
            # Inside the part but past its span (and clear of both edges): NOT_WITHIN_SPAN.
            if valid_to + M < now < part_start + tw.t - M:
                with may_revert() as ex:
                    self._pf(id, caller)
                assert ex.value == IConditionalOrder.OrderNotValid(TWAP_NOT_WITHIN_SPAN)
                return "twap not within span"
            if now > valid_to - M:
                return "twap near span boundary"

        # Live part -> fund exactly one part and poll. The digest uses the validTo recomputed from
        # the poll block itself, so small drift does not matter.
        need = tw.part_sell_amount
        have = self.balances[token][funder_addr]
        if have < need:
            self._fund(token, funder_addr, need - have, caller)
        tx = self._pf(id, caller)
        digest = self._twap_digest(tw, self._twap_valid_to(tw, tx.block.timestamp))
        if digest in self.funded[id]:
            assert tx.return_value is False
            assert not any(isinstance(e, ComposableCowPoller.Pulled) for e in tx.events)
        else:
            assert tx.return_value is True
            assert ComposableCowPoller.Pulled(id=id, orderDigest=digest, amount=need) in tx.events
            self.balances[token][funder_addr] -= need
            self.balances[token][owner_addr] += need
            self.funded[id].add(digest)
        return None

    def _poll_stoploss(self, id: bytes32, sl: StopLossOrder, owner_addr: Address,
                       funder_addr: Address, caller) -> str | None:
        # A fixed sell/buy order that only becomes tradeable once the oracle price ratio falls to or
        # through the strike; the order itself is fixed by the staticInput, so its digest is
        # constant. Each scenario below makes exactly one guard fail, so the expected revert does not
        # depend on the handler's internal check ordering.
        token = self.token_by_addr[sl.sell_token]
        o_sell = self._oracle(sl.sell_oracle)
        o_buy = self._oracle(sl.buy_oracle)
        digest = self._stoploss_digest(sl)
        M = self._TIMING_MARGIN
        # `latest` timestamp; the poll block is a few seconds later (<= M), which the margin absorbs.
        now = chain.blocks["latest"].timestamp

        # Expiry is checked before any oracle read and applies even to an already-funded order.
        if now > sl.valid_to + M:
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.OrderNotValid(SL_ORDER_EXPIRED)
            return "sl expired"
        if now >= sl.valid_to - M:
            return "sl near expiry boundary"

        scenario = random.choice(["success", "not_reached", "stale", "invalid"])

        if scenario == "invalid":
            # Non-positive base price => OrderNotValid(oracle invalid price). Quote stays positive so
            # invalid-price is the only failing guard.
            o_sell.setAnswer(0, from_=caller)
            o_buy.setAnswer(10 ** 18, from_=caller)
            o_sell.setStaleDelay(0, from_=caller)
            o_buy.setStaleDelay(0, from_=caller)
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.OrderNotValid(SL_ORACLE_INVALID_PRICE)
            return "sl invalid price"

        if scenario == "stale":
            # Both oracles positive but stale => PollTryNextBlock(oracle stale price).
            o_sell.setAnswer(1, from_=caller)
            o_buy.setAnswer(10 ** 30, from_=caller)
            o_sell.setStaleDelay(sl.max_stale + 10 ** 6, from_=caller)
            o_buy.setStaleDelay(sl.max_stale + 10 ** 6, from_=caller)
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.PollTryNextBlock(SL_ORACLE_STALE_PRICE)
            return "sl stale"

        if scenario == "not_reached":
            # base huge / quote tiny => rate far above strike => PollTryNextBlock(strike not reached).
            o_sell.setAnswer(10 ** 30, from_=caller)
            o_buy.setAnswer(1, from_=caller)
            o_sell.setStaleDelay(0, from_=caller)
            o_buy.setStaleDelay(0, from_=caller)
            assert not self._sl_triggered(10 ** 30, sl.sell_dec, 1, sl.buy_dec, sl.strike)
            with may_revert() as ex:
                self._pf(id, caller)
            assert ex.value == IConditionalOrder.PollTryNextBlock(SL_STRIKE_NOT_REACHED)
            return "sl strike not reached"

        # success: base tiny / quote huge, fresh => rate <= strike => order produced.
        o_sell.setAnswer(1, from_=caller)
        o_buy.setAnswer(10 ** 30, from_=caller)
        o_sell.setStaleDelay(0, from_=caller)
        o_buy.setStaleDelay(0, from_=caller)
        assert self._sl_triggered(1, sl.sell_dec, 10 ** 30, sl.buy_dec, sl.strike)
        need = sl.sell_amount
        have = self.balances[token][funder_addr]
        if have < need:
            self._fund(token, funder_addr, need - have, caller)
        tx = self._pf(id, caller)
        if digest in self.funded[id]:
            assert tx.return_value is False
            assert not any(isinstance(e, ComposableCowPoller.Pulled) for e in tx.events)
        else:
            assert tx.return_value is True
            assert ComposableCowPoller.Pulled(id=id, orderDigest=digest, amount=need) in tx.events
            self.balances[token][funder_addr] -= need
            self.balances[token][owner_addr] += need
            self.funded[id].add(digest)
        return None

    @flow(weight=25)
    def flow_advance_time(self) -> str | None:
        # Move the clock so TWAP bundles cross parts and eventually finish, span gaps open up, and
        # StopLoss orders expire, instead of waiting on per-transaction timestamp creep.
        dt = random.choice([
            random_int(1, 300),
            random_int(300, 4000),
            random_int(4000, 100_000),
            random_int(100_000, 600_000),
        ])
        chain.mine(lambda t: t + dt)

    @flow(weight=40)
    def flow_replay_after_revoke(self) -> str | None:
        # Funding history has to survive a schedule update, or an old order could be replayed: revoke
        # a funded schedule, re-register the same identity at the bumped epoch, then poll -- false,
        # nothing moved, because funded[id][digest] persisted. Only fixed mock orders qualify; a TAT
        # digest moves with balance and time, so it never gives a stable digest to replay.
        candidates = []
        for i in self._pollable_ids():
            sch = self.schedules[i]
            sp = self.order_specs[i]
            if not isinstance(sp, PollerTestHandler.OrderSpec):
                continue
            if sp.revertOrder:
                continue
            if (sch.owner, self._params_hash(sch)) not in self.created:
                continue
            if self._order_digest(sp) in self.funded[i]:
                candidates.append(i)
        if not candidates:
            return "no funded schedule to replay"

        id = random.choice(candidates)
        schedule = self.schedules[id]
        spec = self.order_specs[id]
        assert isinstance(spec, PollerTestHandler.OrderSpec)
        digest = self._order_digest(spec)

        # 1) revoke
        tx = self.poller.revoke(
            handler=schedule.handler, owner=schedule.owner, salt=schedule.salt, from_=schedule.funder)
        self._revoke_effect(id, schedule, tx)

        # 2) re-register the identical schedule at the incremented epoch
        new_schedule = dataclasses.replace(schedule, authEpoch=uint96(self.auth_epochs[id]))
        tx = self.poller.register(new_schedule, from_=new_schedule.funder)
        self._register_effect(id, new_schedule, spec, tx)

        # 3) poll: same order -> same digest -> already funded -> false, no transfer
        tx = self._pf(id, random_account())
        assert tx.return_value is False
        assert not any(isinstance(e, ComposableCowPoller.Pulled) for e in tx.events)
        return None

    @flow(weight=12)
    def flow_twap_cabinet(self) -> str | None:
        # t0 == 0 TWAP whose start time comes from the cabinet, written by createWithContext +
        # CurrentBlockTimestampFactory. The handler reads cabinet(owner, ctx), so a poller passing
        # the wrong ctx would miss the lookup. Registered as non-pollable so nothing else polls it
        # after a later `remove` clears the cabinet; span 0 keeps the poll inside the part.
        n = random_int(2, 6)
        t = random_int(600, 86400)
        sell = self._fundable_sell_token()
        buy = random.choice(self.tokens).address
        while buy == sell:
            buy = random.choice(self.tokens).address
        receiver = random_account().address if random_bool() else Address(0)
        app_data = random_bytes32()
        part_amt = random_int(1, 10 ** 21)
        min_lim = random_int(1, 10 ** 21)
        data = TWAPOrder.Data(
            sellToken=IERC20(sell), buyToken=IERC20(buy), receiver=receiver,
            partSellAmount=uint256(part_amt), minPartLimit=uint256(min_lim), t0=uint256(0),
            n=uint256(n), t=uint256(t), span=uint256(0), appData=app_data)
        static = abi.encode(data)

        funder = random_account()
        owner = random_account()
        salt = random.choice(SALTS)
        id = self._get_id(funder, TWAP_HANDLER, owner, salt)
        if id in self.schedules:
            return "id busy"

        schedule = ComposableCowPoller.Schedule(
            handler=TWAP_HANDLER, authEpoch=uint96(self.auth_epochs[id]), funder=funder.address,
            owner=owner.address, salt=salt, staticInput=static)
        tx = self.poller.register(schedule, from_=funder)
        self._register_effect(id, schedule, None, tx)  # None => excluded from the general poll rotation

        # Fund first, so no transaction sits between the cabinet write and the poll.
        token = self.token_by_addr[sell]
        have = self.balances[token][funder.address]
        if have < part_amt:
            self._fund(token, funder.address, part_amt - have, funder)

        params = IConditionalOrder.ConditionalOrderParams(
            handler=TWAP_HANDLER, salt=salt, staticInput=static)
        params_hash = keccak256(abi.encode(params))
        ctx_tx = self._rpc_retry(lambda: COMPOSABLE_COW.createWithContext(
            params, CURRENT_BLOCK_TIMESTAMP_FACTORY, b"", random_bool(), from_=owner))
        self.created.add((owner.address, params_hash))
        self.all_created_pairs.add((owner.address, params_hash))
        # CurrentBlockTimestampFactory stores block.timestamp of the createWithContext call into the
        # cabinet, which becomes the TWAP bundle's effective t0.
        tw = TwapOrder(
            sell_token=sell, buy_token=buy, receiver=receiver, part_sell_amount=part_amt,
            min_part_limit=min_lim, t0=ctx_tx.block.timestamp, n=n, t=t, span=0, app_data=app_data)

        tx = self._pf(id, random_account())
        valid_to = self._twap_valid_to(tw, tx.block.timestamp)
        digest = self._twap_digest(tw, valid_to)
        assert tx.return_value is True
        assert ComposableCowPoller.Pulled(id=id, orderDigest=digest, amount=part_amt) in tx.events
        self.balances[token][funder.address] -= part_amt
        self.balances[token][owner.address] += part_amt
        self.funded[id].add(digest)
        return None

    @flow(weight=8, max_times=3)
    def flow_deploy_bad_factory(self) -> str | None:
        # Constructor guard: deploying with a code-less CowShed factory must revert.
        codeless = random_account().address  # an EOA has no code
        with may_revert() as ex:
            ComposableCowPoller.deploy(COMPOSABLE_COW, ICowShedFactory(codeless))
        assert ex.value == ComposableCowPoller.InvalidCowShedFactory()
        return "bad factory deploy"

    # ------------------------------------------------------------------ invariants

    @invariant()
    def invariant_schedules(self) -> None:
        for id in self.all_ids:
            onchain = self.poller.schedules(id)
            assert onchain.authEpoch == self.auth_epochs[id]
            if id in self.schedules:
                assert onchain == self.schedules[id]
            else:
                assert onchain.funder == Address(0)

    @invariant()
    def invariant_funded(self) -> None:
        for id, digests in self.funded.items():
            for digest in digests:
                assert self.poller.funded(id, digest) is True

    @invariant()
    def invariant_balances(self) -> None:
        # `balanceOf` on a forked token fetches mainnet state on demand, so it can hit the flake;
        # `_rpc_retry` is a no-op for the local mocks.
        tokens: list = list(self.tokens) + list(self.real_tokens)
        for token in tokens:
            for acc in chain.accounts:
                onchain = self._rpc_retry(lambda t=token, a=acc: t.balanceOf(a))
                assert self.balances[token][acc.address] == onchain

    @invariant()
    def invariant_poller_holds_nothing(self) -> None:
        # The poller is non-custodial: pollFunds moves the sellToken funder -> owner via
        # safeTransferFrom and never holds it, so its balance must be zero for every token at all
        # times. Anything else means funds got stuck.
        for token in list(self.tokens) + list(self.real_tokens):
            assert self._rpc_retry(lambda t=token: t.balanceOf(self.poller)) == 0

    @invariant()
    def invariant_created(self) -> None:
        # `self.created` mirrors ComposableCoW.singleOrders(owner, paramsHash), which decides the
        # OrderNotLive-vs-success dispatch in flow_poll_funds, so assert it both ways: True for live
        # authorizations, False for removed ones. A full sweep every period would dominate runtime,
        # so it rotates through a bounded window instead.
        pairs = list(self.all_created_pairs)
        if not pairs:
            return
        window = 25
        n = len(pairs)
        start = self._created_check_idx % n
        self._created_check_idx = (self._created_check_idx + window) % n
        for i in range(min(window, n)):
            owner, ph = pairs[(start + i) % n]
            onchain = self._rpc_retry(lambda o=owner, h=ph: COMPOSABLE_COW.singleOrders(o, h))
            assert onchain == ((owner, ph) in self.created)

    # ------------------------------------------------------------------ misc

    def _domain(self) -> Eip712Domain:
        return Eip712Domain(
            name="ComposableCowPoller",
            version="1",
            chainId=chain.chain_id,
            verifyingContract=self.poller,
        )


# The CowShed factory above only appeared around block 25.8M, so the fork has to be later than that
# for the *FromShed flows to have a real shed to call.
@chain.connect(fork=f"{os.getenv('ETH_RPC_URL')}")
#@chain.connect(fork=f"{os.getenv('ETH_RPC_URL')}@25850000")
def test_cow():
    ComposableCowPollerTest().run(100, 10_000)
