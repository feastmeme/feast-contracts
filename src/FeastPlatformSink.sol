// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {FeastGenesis} from "./FeastGenesis.sol";
import {IFeastGenesisRecipient} from "./IFeastGenesisRecipient.sol";
import {IFeastGuardian} from "./IFeastGuardian.sol";

interface IFeastBurnableCoin {
    function burn(uint256 amount) external;
}

/// @notice What the sink asks the launch window: when it closes, which is when
///         the platform coin can first be in anyone's hands.
interface IFeastLaunchWindowClose {
    function endsAt() external view returns (uint64);
}

/// @title Where the platform's fee share goes: descending-price redemption
/// @notice Every asset the hook sends here is offered for the platform coin at a
///         price that falls continuously — halving every hour — and rises after
///         each sale in proportion to the share of the lot sold. Whoever brings
///         the platform coin takes the asset, and the platform coin is burned on
///         the spot.
///
/// @dev The v1.1 floor's third layer, as the owner ruled (Q16): **no oracle, no
///      route, nothing to manipulate.** A taker chooses to trade at a published
///      price; the protocol never swaps and never asks anyone what an asset is
///      worth. It works for any asset the platform share arrives in, including a
///      quote with no market at all. The sink never sells a lot below what the
///      most eager taker pays *for that lot*; with competition that is the
///      market. Time in which there was no lot to price is not a descent
///      (v1.6.2, `CA-fb2e051555`).
///
///      - A lot starts at `SINK_START_PRICE_Q128` when someone opens it (anyone
///        may, over a lot that holds something) — far above any real value, so
///        it can only descend into the market.
///      - The price halves every `SINK_HALF_LIFE`, linearly within each half-life.
///      - **A descent prices the lot it was opened over** (v1.6.2). A lot that
///        now holds at least `SINK_REOPEN_MULTIPLE` times what it held when its
///        descent began — including anything at all after the lot was emptied —
///        is a different lot: it is priced from the start price again (never
///        under the floor) until someone opens a descent over it, and a take
///        from it pays that price and restarts the descent's curve there
///        (v1.6.25), so no lot comes back into the band onto a clock that ran
///        while it read from the top. So the clock never runs on an empty lot,
///        and the taker whose own refill arrives cannot buy it at the price
///        the smaller lot had descended to. Only `open` sets the size a
///        descent prices: a take may lower it, never
///        raise it, so no sequence of donations and takes can manufacture a
///        reference size that no descent ever stood over. `open` is guarded
///        against re-entry for the same reason: an asset that calls back during
///        a take must not be able to start a descent over a balance the take is
///        in the middle of moving. A lot that now holds LESS than its descent
///        priced — only an asset that shrinks a holder's balance can do that —
///        is a different lot too.
///      - A take of fraction `f` of the lot re-anchors the price at `price ×
///        (1 + f)`: a dust take moves it by dust, so nobody can hold the price up
///        by taking crumbs.
///      - No descent starts before the sink's scheduled opening, which genesis
///        sets once to the moment the launch window closes. Until then nobody
///        can hold the coin a take is paid in, and a price falling with no
///        possible bidder is a timer rather than a market (v1.6.2).
///      - Once an asset has sold *inside the descent that is running*, its price
///        never falls below that sale's price
///        — weighted by the share of the lot it took — halved
///        `SINK_FLOOR_HALVINGS` times. That floor has a clock of its own,
///        halving every `SINK_FLOOR_HALF_LIFE` since the sale that set it, so a
///        lot the market has left behind comes back within reach in days rather
///        than never (v1.6.2). **A take may raise that floor and never lower
///        it**, and a take that does not raise it does not restart its clock
///        either, so a one-wei purchase cannot buy away what a real sale
///        established (v1.6.3). "Never lower" is exact at the sale and within
///        one raw price unit afterwards, because a raising write starts a fresh
///        curve and the decay truncates (v1.6.3 round 2). Opening a new descent
///        clears it. Never below one unit.
///      - Nothing can strand: any balance that someone has opened a descent over
///        can always be taken at a positive price, and a frozen asset refuses
///        only its own takes. A lot nobody opens does not sell, which is the
///        safe way round: it reads at the start price until someone does.
contract FeastPlatformSink is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOpened(address asset);
    error AlreadyOpened(address asset);
    error NotForSale(address asset);
    error NothingToOffer(address asset);
    error PlatformCoinNotLive(address coin);
    error NotGenesisKey();
    error AlreadyScheduled(uint64 opensAt);
    error NotTheLaunchWindow(address window);
    error WindowServesAnotherCoin(address window);
    error WindowAlreadyClosed(uint64 closes);
    error WindowTooFarOut(uint64 closes, uint64 bound);
    error NotOpenYet(uint64 opensAt);
    error NothingToTake();
    error MoreThanHeld(uint256 requested, uint256 held);
    error CostAboveLimit(uint256 cost, uint256 limit);

    event Opened(address indexed asset, uint256 priceQ128, uint256 offered);
    event Taken(address indexed asset, address indexed taker, uint256 amountOut, uint256 platformCoinBurned, uint256 priceQ128);
    event StrayBurned(uint256 amount);
    event Scheduled(address indexed window, uint64 opensAt);

    struct Lot {
        uint256 anchor;
        uint64 anchoredAt;
        /// @dev What `guardian.frozenSeconds()` read when this descent was
        ///      anchored. The descent's clock is wall time MINUS the frozen time
        ///      since then, so the price does not fall while nobody may buy —
        ///      see `_price`.
        uint64 frozenAtAnchor;
        /// @dev When the floor's own clock was last restarted: the last sale
        ///      that RAISED the floor, not merely the last sale (v1.6.2, and
        ///      v1.6.3 for the distinction).
        uint64 lastSaleAt;
        /// @dev What `guardian.frozenSeconds()` read at that same sale — the
        ///      floor's own frozen checkpoint, and NOT `frozenAtAnchor`.
        ///      v1.6.14 read the floor's clock (`lastSaleAt`) against the
        ///      DESCENT's checkpoint, and the two are written at different
        ///      instants: `frozenAtAnchor` is written when a descent is
        ///      anchored (by `open`, and since v1.6.25 by a take that restarts
        ///      one), and only a RAISING take moves `lastSaleAt`. So one raw unit bought after a freeze
        ///      charged the floor for hours in which nobody could buy — the
        ///      whole discount v1.6.14 had just removed, for the price of a
        ///      dust purchase (v1.6.14 round: `P3` HIGH, `P16b` HIGH,
        ///      `P3-claude` MEDIUM; PoC
        ///      `test_aDustTakeDoesNotSpendTheFreezeOnTheFloor`).
        uint64 frozenAtSale;
        /// @dev What the floor is measured from: the price of the last sale
        ///      that RAISED the floor, weighted by the share of the lot that
        ///      sale took, so a dust take seeds a floor of dust and a whole-lot
        ///      take seeds the whole price (v1.6.2 round 4). A sale that does
        ///      not beat the standing floor leaves this and `lastSaleAt`
        ///      untouched (v1.6.3).
        uint256 floorBase;
        /// @dev What the lot held when this descent began; zero while no descent
        ///      is running over it (v1.6.2).
        uint256 offered;
    }

    uint256 internal constant ONE = 1 << 128;
    /// @dev The most a descent's anchor may ever reach: `2^32` times the price
    ///      every descent opens at, which is `2^224`.
    ///
    ///      **Not "twice the opening price", and the difference is the whole
    ///      point.** `take`'s growth term is documented as "a sale of share `s`
    ///      raises the anchor by `s`", and that COMPOUNDS down a shrinking lot
    ///      with no refill anywhere: twelve takes of half the lot each raise it
    ///      by `1.5^12`, about 129x, and
    ///      `test_aRefillIsPricedFromTheTopButNeverUnderTheFloor` has asserted
    ///      exactly that since v1.6.2. In the limit of small takes the product
    ///      approaches the lot's RAW UNIT COUNT, so for an 18-decimal asset the
    ///      honest ceiling is around `1e20` — which is why no bound drawn from
    ///      the sale arithmetic can be both above every honest sequence and
    ///      below a word. It has to be drawn from the MONEY instead.
    ///
    ///      `take` already records the measurement: the platform coin's entire
    ///      `1e27` supply buys 54 210 108 raw units at the opening price. At
    ///      `2^32` times that price the whole supply buys about a hundredth of
    ///      one raw unit, so an anchor at this ceiling prices the lot beyond
    ///      every buyer that can ever exist and saturating there costs nothing
    ///      anyone could have paid.
    ///
    ///      What it buys: `anchor <= 2^224` makes the sum in `take` at most
    ///      `2^225`, so the addition cannot panic and an opened lot cannot be
    ///      put beyond reach (`HK19` HIGH, v1.6.19 round).
    uint256 internal constant ANCHOR_CEILING = FeastGenesis.SINK_START_PRICE_Q128 << 32;

    IERC20 public immutable platformCoin;
    /// @notice The one address that may schedule the sink's opening, once, and
    ///         holds no other power here before or after.
    address public immutable genesisKey;
    /// @notice When the first descent may start: the moment the launch window
    ///         closes, read from the window genesis names, so that no descent
    ///         runs while nobody can obtain the coin it is paid in. Zero until
    ///         genesis names that window (v1.6.2, rounds 5 and 6).
    uint64 public opensAt;
    mapping(address asset => Lot) internal _lots;

    constructor(address platformCoin_, address genesisKey_, address guardian_) {
        platformCoin = IERC20(platformCoin_);
        genesisKey = genesisKey_;
        guardian = IFeastGuardian(guardian_);
    }

    /// @notice The brake. It can pause this contract's outflows for at most 72
    ///         hours at a time and can do nothing else here. See `FeastGuardian`.
    IFeastGuardian public immutable guardian;

    error Frozen();

    /// @dev This contract belongs to no single pool, so it asks the whole-system
    ///      question. A per-pool freeze is for a pool's trading and its own fee
    ///      claims; anything that spans coins is `ALL` or nothing.
    function _requireUnfrozen() internal view {
        if (guardian.isFrozenAll()) revert Frozen();
    }


    /// @notice Schedule the sink's opening by naming the launch window. The
    ///         genesis key's only power here, usable once, and gone the moment
    ///         it is used.
    /// @dev The sink is built at the factory's opening, against the coin's
    ///      predicted address, and the coin is created by genesis weeks later —
    ///      and even then its whole supply sits in a gated pool, in an
    ///      unsettled launch window and in unstarted vesting until that window
    ///      closes. A descending price during any of that is not a market, it
    ///      is a timer: nobody can outbid anybody, so whoever opened the lot
    ///      buys it at whatever the clock reached (round 5, hunter lens).
    ///
    ///      So the sink opens when the window does its settling — the moment
    ///      the first FEAST can be held by anyone. The key's discretion is
    ///      bounded at both ends: never a time already past, and never further
    ///      out than the longest gate the hook itself will accept, beyond which
    ///      the coin's own pool is open regardless.
    ///
    ///      The key names the window; it does not name a time. A time it could
    ///      choose would make the opening a promise — it could be brought
    ///      forward to the start of the very period this exists to exclude
    ///      (round 6, both lenses). Read from the window, it is a mechanism, and
    ///      the only discretion left is which window: the same identity claim
    ///      genesis already trusts the key for, and which the sink checks the
    ///      way the factory does, by asking the contract what it is.
    ///
    ///      Called once, at genesis, before any descent can exist. No external
    ///      call on any priced path — `open`, `take` and the price make none —
    ///      and no oracle: the sink still asks nobody what anything is worth.
    function schedule(address window) external {
        if (msg.sender != genesisKey) revert NotGenesisKey();
        if (opensAt != 0) revert AlreadyScheduled(opensAt);
        if (IFeastGenesisRecipient(window).genesisRole() != FeastGenesis.ROLE_LAUNCH_WINDOW) {
            revert NotTheLaunchWindow(window);
        }
        if (IFeastGenesisRecipient(window).platformCoin() != address(platformCoin)) {
            revert WindowServesAnotherCoin(window);
        }
        uint64 closes = IFeastLaunchWindowClose(window).endsAt();
        // Round `v1.6.4` G2 (`CA-4ce8a94deb`, both lens families): the two-ended
        // bound the docstring above advertises was not implemented — `endsAt()`
        // was copied through, and a window closing a year out was accepted. The
        // predicate below is the hook's own, at `FeastHook.sol:224-231`, on the
        // same constant, so the sink and the hook refuse the same set.
        if (closes <= block.timestamp) revert WindowAlreadyClosed(closes);
        uint64 bound = uint64(block.timestamp + FeastGenesis.MAX_GATE_DURATION);
        if (closes > bound) revert WindowTooFarOut(closes, bound);
        opensAt = closes;
        emit Scheduled(window, closes);
    }

    /// @notice What genesis and the hook's exit ask the sink.
    function genesisRole() external pure returns (bytes32) {
        return FeastGenesis.ROLE_PLATFORM_SINK;
    }

    /// @notice Start `asset`'s descending price. Anyone may, over a lot that
    ///         holds something and that no descent already prices: the first
    ///         time it holds anything, again once it holds at least
    ///         `SINK_REOPEN_MULTIPLE` times what it held when the last descent
    ///         began, and again if it holds less than that — which only an asset
    ///         that shrinks a holder's balance can bring about.
    /// @dev The only thing this call can do is *lower* a price: it starts the
    ///      descent for a lot that is otherwise read at the start price. A lot
    ///      nobody opens simply does not sell, which is the safe way round.
    ///
    ///      Refused on exactly the complement of what `_price` prices, because
    ///      both ask `_pricesThisLot`. Whenever the price function refuses to
    ///      price the lot in front of it, this call accepts it, and whenever it
    ///      does price it, this call refuses — so no lot can reach a state where
    ///      its descent can be neither used nor replaced (round 3, both lenses).
    function open(address asset) external nonReentrant {
        _requireUnfrozen();
        if (asset == address(platformCoin)) revert NotForSale(asset);
        // A descent whose takes nobody can pay is not a market, it is a timer.
        // The sink is deployed against the platform coin's predicted address and
        // genesis creates the coin later, so there is a window - every asset's
        // first weeks - in which every take would revert for want of a coin to
        // pay in. No descent starts in it (round 4). The hook makes the mirror
        // check at the other end of this path (`FeastHook.releasePlatformFees`).
        if (address(platformCoin).code.length == 0) revert PlatformCoinNotLive(address(platformCoin));
        // Belt and braces with the line above: the coin must exist, and the
        // window that puts it in anyone's hands must have closed.
        if (opensAt == 0 || block.timestamp < opensAt) revert NotOpenYet(opensAt);
        Lot storage lot = _lots[asset];
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (held == 0) revert NothingToOffer(asset);
        if (_pricesThisLot(lot, held)) revert AlreadyOpened(asset);
        lot.anchor = FeastGenesis.SINK_START_PRICE_Q128;
        lot.anchoredAt = uint64(block.timestamp);
        lot.frozenAtAnchor = guardian.frozenSeconds();
        lot.offered = held;
        // A floor is what a sale inside a descent says about the lot that
        // descent priced. A new descent over a different lot inherits none of
        // it: carrying one across let a whole-lot purchase of a single raw unit
        // bound a lot a million times larger for as long as the floor's own
        // halving took to come down (round 5, both lenses).
        lot.floorBase = 0;
        lot.lastSaleAt = 0;
        lot.frozenAtSale = 0;
        emit Opened(asset, lot.anchor, held);
    }

    /// @notice Platform coin per raw unit of `asset` right now, 128.128.
    function priceQ128(address asset) public view returns (uint256 price) {
        return _price(asset, _lots[asset], IERC20(asset).balanceOf(address(this)));
    }

    /// @dev The price of `held` raw units, given the lot's descent.
    function _price(address asset, Lot storage lot, uint256 held) private view returns (uint256 price) {
        if (lot.anchoredAt == 0) revert NotOpened(asset);
        // A lot no descent prices is read from the start price — still floored,
        // because a lot whose last sale was above the start price has a floor
        // above it too, and this reading may not sell under it, nor may `open`
        // raise a quote by applying a floor this reading skipped (round 1 H2).
        // A take restarts the curve at exactly this reading before it prices
        // (v1.6.25), so it is also what the curve says when a take arrives.
        if (!_pricesThisLot(lot, held)) return _atLeastTheFloor(lot, FeastGenesis.SINK_START_PRICE_Q128);
        // **The descent's clock stops while the brake is down.** Wall time minus
        // the frozen time since this descent was anchored.
        //
        // Without this, a freeze was a discount the guardian could give itself:
        // `SINK_HALF_LIFE` is ONE HOUR and a freeze may run 72, so one pull of
        // the brake halved the price of everything the sink held seventy-two
        // times while every buyer was locked out — and the guardian, the only
        // address that knew when it would end, could unfreeze and take in the
        // same transaction. Three units of the v1.6.12 round found it, one in
        // each family and one twice; `test/audit/poc/FreezeRunsTheDescentClock.t.sol`
        // is the PoC.
        //
        // `take` stays freezable: a defect in the sink itself has to be
        // stoppable. What must not happen is the PRICE moving while it is.
        uint256 frozen = guardian.frozenSeconds() - lot.frozenAtAnchor;
        uint256 wall = block.timestamp - lot.anchoredAt;
        uint256 elapsed = wall > frozen ? wall - frozen : 0;
        uint256 halvings = elapsed / FeastGenesis.SINK_HALF_LIFE;
        price = halvings >= 255 ? 0 : lot.anchor >> halvings;
        // Linear inside a half-life, so the price is continuous.
        uint256 into = elapsed % FeastGenesis.SINK_HALF_LIFE;
        // v1.6.4 G1 sweep: `lot.anchor` is re-anchored upward on every sale and
        // has no static ceiling, so `price * into` had none either.
        price -= Math.mulDiv(price, into, 2 * FeastGenesis.SINK_HALF_LIFE);
        price = _atLeastTheFloor(lot, price);
    }

    /// @dev Does the descent recorded for this lot price a lot of `held` raw
    ///      units? Exactly on `offered <= held < SINK_REOPEN_MULTIPLE * offered`,
    ///      and this one predicate answers for both readers — the price and the
    ///      permission to open — so the two can never disagree.
    ///
    ///      Inside the sink, `held == offered` after every write it makes:
    ///      `open` records what it opened over, and `take` records what it
    ///      leaves. So `held > offered` means something arrived (a fee release,
    ///      a donation), and `held < offered` means the asset itself took a
    ///      holder's balance away (a rebase, a clawback, a burn on the holder) —
    ///      an issuer power, and the VENUE boundary.
    ///
    ///      Either way the descent stops being evidence about what is here: it
    ///      priced a lot at most half this size, or one that is no longer here.
    ///      Both read from the top, and both may be opened again by anyone.
    function _pricesThisLot(Lot storage lot, uint256 held) private view returns (bool) {
        return held >= lot.offered && held / FeastGenesis.SINK_REOPEN_MULTIPLE < lot.offered;
    }

    /// @dev **The standing floor right now, on its own clock.** A sale's price —
    ///      weighted by the share of the lot it took — halved
    ///      `SINK_FLOOR_HALVINGS` times is where the descent stops *at that
    ///      sale*; from then on it halves every `SINK_FLOOR_HALF_LIFE`,
    ///      linearly within each half-life, exactly as the main clock does.
    ///      Without that, one sale pins an asset above what anyone will pay for
    ///      it for ever, and a reopen from the start price stops at the same pin
    ///      (v1.6.2, H2).
    ///
    ///      One reader for two callers, which is the point of it being here:
    ///      `_atLeastTheFloor` asks it what the price may not fall below, and
    ///      `take` asks it what a new sale must beat to replace it. Before
    ///      v1.6.3 only the first caller existed and `take` wrote over the floor
    ///      unconditionally, so a one-wei purchase erased what a real sale had
    ///      set (`CA-b229a31396`).
    ///
    ///      `lastSaleAt` is read only when `floorBase` is nonzero, and `open`
    ///      and `take` are the only writers of either — both write the TRIPLE
    ///      `floorBase` / `lastSaleAt` / `frozenAtSale` together, so there is no
    ///      state in which a base has no clock or a clock no checkpoint. They
    ///      are the floor's own three, and `anchoredAt` / `frozenAtAnchor` are
    ///      the descent's; the two pairs are written at different instants and
    ///      reading one against the other is what v1.6.14 got wrong.
    function _floorNow(Lot storage lot) private view returns (uint256 floor_) {
        floor_ = lot.floorBase >> FeastGenesis.SINK_FLOOR_HALVINGS;
        if (floor_ == 0) return 0;
        // **Open time, like the descent above it.** `take` is frozen and this
        // clock was not, so a freeze cut the floor that protects the lot — the
        // same discount the descent gave before v1.6.13, arriving through the
        // other half of the price. Four units of the v1.6.13 round found it,
        // across both families; measured, the floor fell by a factor of eight
        // across one 72-hour freeze.
        //
        // `lastSaleAt` and `frozenAtSale` are written together by `take`, inside
        // the one branch that raises the floor, and `open` clears the pair too.
        //
        // v1.6.14 read this clock against `frozenAtAnchor` instead, which every
        // take writes. A take that does not raise the floor therefore moved the
        // checkpoint without moving the clock, and the frozen time between the
        // last raising sale and that take was charged to the floor as OPEN
        // time. One raw unit is enough and anyone may buy it.
        // The 2026-09-13 ruling is untouched: the floor still declines slowly
        // over time and is never pushed down by a take — a freeze may neither
        // accelerate that decline nor spend it.
        uint256 frozenSince = guardian.frozenSeconds() - lot.frozenAtSale;
        uint256 wallSince = block.timestamp - lot.lastSaleAt;
        uint256 since = wallSince > frozenSince ? wallSince - frozenSince : 0;
        uint256 halvings = since / FeastGenesis.SINK_FLOOR_HALF_LIFE;
        floor_ = halvings >= 255 ? 0 : floor_ >> halvings;
        uint256 into = since % FeastGenesis.SINK_FLOOR_HALF_LIFE;
        // v1.6.4 G1 sweep: `floorBase` tracks sale prices, same absence of a ceiling.
        floor_ -= Math.mulDiv(floor_, into, 2 * FeastGenesis.SINK_FLOOR_HALF_LIFE);
    }

    /// @dev The published price, held up by the standing floor. Never below one
    ///      unit, so a take always burns something.
    function _atLeastTheFloor(Lot storage lot, uint256 price) private view returns (uint256) {
        uint256 floor_ = _floorNow(lot);
        if (price < floor_) price = floor_;
        if (price == 0) price = 1;
        return price;
    }

    /// @notice Take `amountOut` of `asset`, paying at most `maxCoinIn` of the
    ///         platform coin, which is burned.
    function take(address asset, uint256 amountOut, uint256 maxCoinIn) external nonReentrant returns (uint256 cost) {
        _requireUnfrozen();
        if (amountOut == 0) revert NothingToTake();
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (amountOut > held) revert MoreThanHeld(amountOut, held);
        Lot storage lot = _lots[asset];
        // **A lot the view reads from the top is sold from the top, and its
        // descent restarts there** (v1.6.25, AstraSec M-3). Outside the band
        // `_price` answers the start price, floored, and writes nothing, and
        // until v1.6.25 nothing else wrote either: the curve `open` anchored
        // kept its clock while the quote said the top. A take that brought the
        // lot back into the band brought it back onto a curve nobody could see.
        // Double a lot of 100e18, wait eighty hours, take one raw unit at the
        // top for 2^64 wei, and the other 199.99e18 units cost 0.288 FEAST
        // (measured; `test/audit/astrasec/M3_SinkDescentOutsideTheBand.t.sol`).
        //
        // So the take restarts the curve where the quote already is, and only
        // then prices: the start price, now, at the guardian's frozen seconds
        // now. Those are `open`'s three writes. The charge does not change, it
        // is `_atLeastTheFloor(lot, START)` either way, which is the quote the
        // view published; the curve now agrees with it.
        //
        // `open`'s other writes are deliberately NOT made here:
        //
        //   - **The floor stays.** A take may raise the floor and never lower it
        //     (v1.6.3), and the quote this take is charged includes the floor
        //     (round 1 H2), so clearing it would sell under the published price.
        //   - **The size is never raised.** It is lowered to what is here when
        //     the lot holds less than its descent priced, and left alone
        //     otherwise: only `open` sets the size a descent prices (round 1
        //     H1). Writing `offered = held`, as `open` does, put a refilled lot
        //     back in the band under the floor its last sale left, and the
        //     keeper's `open` that clears that floor then reverted
        //     `AlreadyOpened`: round 5's carried floor, back for one unit at the
        //     top. Measured: `test_aCarriedFloorIsClearedByOpeningAndNotByASale`
        //     fails with it.
        //
        // Nobody gains a power by this: `open` is permitted on exactly this
        // condition, and writes more. A lot never opened is `_price`'s
        // `NotOpened`, not a take's to start.
        //
        // **What it cannot reach, stated.** A lot that leaves the band and comes
        // back with no take in between revives the curve it left, because no
        // write happened at which the sink could see it go. Only an asset that
        // shrinks a holder's balance can make a lot leave from below and an
        // arrival bring it back. That is B9's declared limit (`docs/plan.md`),
        // witnessed by `test_theDeclaredLimitOfWhatAShrunkenLotCanBeToldFrom`;
        // the mitigation is the keeper's `open`.
        if (lot.anchoredAt != 0 && !_pricesThisLot(lot, held)) {
            lot.anchor = FeastGenesis.SINK_START_PRICE_Q128;
            lot.anchoredAt = uint64(block.timestamp);
            lot.frozenAtAnchor = guardian.frozenSeconds();
            if (held < lot.offered) lot.offered = held;
        }
        // Priced through the same branch as the view, so a taker whose own
        // refill lands in this transaction is quoted the refilled lot's price,
        // not the price the smaller lot had descended to.
        uint256 price = _price(asset, lot, held);
        // v1.6.5 sweep row 21, CLOSED in v1.6.6 (`Q3`). `mulDiv` panics when its
        // RESULT exceeds a word, and this one's does once
        // `amountOut * price > 2^384 - 2^128`: at the opening price
        // `SINK_START_PRICE_Q128 = 2^192` the smallest take that panics is
        // exactly `amountOut = 2^192` raw units (measured). So a lot far larger
        // than any real supply could not be taken in one call, and the refusal
        // was a PANIC where every other limit here has a name.
        //
        // A cost no word can hold is above every limit a caller can pass, since
        // `maxCoinIn` is itself a `uint256` — so the answer is this function's
        // own refusal, saturated. That is the same shape `FeastEmissions.settle`
        // uses for its value cap and `FeastPricer.priceQ128` for a composed
        // price: take the high word of the 512-bit product and decide BEFORE
        // forming a quotient that cannot exist.
        //
        // Nothing reachable changes. The real ceiling on a take is the money:
        // the platform coin's entire `1e27` supply buys **54 210 108 raw units**
        // at the opening price (measured), so every take anybody can pay for is
        // fifty orders of magnitude below the threshold. What this buys is
        // legibility — an impossible take now answers with the name it always
        // had instead of a panic. The sentence below is unchanged and was
        // already true: a lot holding an asset's entire `type(uint256).max`
        // supply can be bought from, and v1.6.3's witness proves it by buying
        // one unit — which does reach this line and computes its cost. What
        // that witness never reached is the OVERFLOW, because one unit at any
        // price this sink publishes is nowhere near it (v1.6.6 round 1, r1v:
        // the first draft of this note said it never reached the line at all).
        // The exact condition, because `mulDiv` here ROUNDS UP and the rounding
        // is what crosses the word at the edge: `ceil(P / 2^128)` fits a word
        // exactly when `P <= 2^384 - 2^128`. In 512-bit terms that is
        // `high < ONE`, and at `high == ONE - 1` also `low <= 2^256 - 2^128`.
        // Guarding only on `high >= ONE` would leave a band one part in `2^256`
        // wide where the floor fits, the remainder is nonzero, and OZ's `+ 1`
        // panics in checked arithmetic — the same one-bit gap between "the
        // intermediate fits" and "the result fits" that this whole sweep is about.
        (uint256 costHigh, uint256 costLow) = Math.mul512(amountOut, price);
        if (costHigh >= ONE || (costHigh == ONE - 1 && costLow > type(uint256).max - ONE + 1)) {
            revert CostAboveLimit(type(uint256).max, maxCoinIn);
        }
        cost = Math.mulDiv(amountOut, price, ONE, Math.Rounding.Ceil);
        if (cost > maxCoinIn) revert CostAboveLimit(cost, maxCoinIn);

        // The same number the lot re-anchored at before v1.6.3, written in a
        // form whose intermediate cannot overflow. `mulDiv(price, held +
        // amountOut, held)` evaluates `held + amountOut` in CHECKED arithmetic
        // before `mulDiv` ever sees it, so a lot holding an asset's entire
        // `type(uint256).max` supply panicked on every take and could never be
        // bought from or reopened (`CA-fad351f89b`). Taking the integer `price`
        // out of the floor is exact — `⌊p(h+a)/h⌋ = p + ⌊pa/h⌋` — and
        // `amountOut ≤ held` is already enforced above, so the added term is at
        // most `price` and the sum at most twice it.
        //
        // **The sale raises the CURVE; it does not restart it** (v1.6.19,
        // owner ruling). `anchor` is multiplied by `1 + amountOut/held` and the
        // clock is left exactly where it was, so from this instant the price is
        // the price it would have been, times the share this sale took. The
        // descent is then MEMORYLESS: a take at any moment leaves the lot on
        // the same curve, and a take of nothing changes nothing. That is the
        // rule inside the band. The restart at the top of this function is of a
        // lot the view was already reading at the start price, and it restarts
        // the curve AT that price, so it puts no chord above anything the
        // published price had descended to; `open` could always do the same.
        //
        // Why it had to change. The curve is exponential by halvings and LINEAR
        // inside each one, and a chord lies ABOVE the exponential it spans.
        // Re-anchoring reset the clock, which put the price back at the top of
        // a fresh chord — so a drip of takes never let it reach the cheap end
        // of one:
        //
        //     continuing:  anchor * 2^(-T/H)             = anchor * e^(-0.693 T/H)
        //     restarting:  anchor * (1 - d/2H)^(T/d)  ->  anchor * e^(-0.5 T/H)
        //
        // — a ratio of `e^(0.193 T/H)`, about 3.2x over six hours in the limit
        // and **2.03x measured** with a take every thirty minutes. One raw unit
        // was enough, and `/burn` gives anyone the button (`HK19-claude`
        // MEDIUM, v1.6.16 round).
        //
        // **The guard tried at v1.6.17 and rejected, recorded so nobody repeats
        // it:** skipping the re-anchor when the sale's own value `sold` floors
        // to zero — the rule the FLOOR has had since v1.6.3 — does not bite. At
        // a lot of 100e18 units and a Q128 price one raw unit is still worth
        // about 5e16, so `sold` is nonzero and the clock reset anyway. The
        // defect was never about dust being rounded away; it was about the
        // clock.
        //
        // **Overflow, and why the argument this comment used to make was wrong**
        // (`HK19` HIGH, v1.6.19 round; PoC
        // `test/audit/poc/SinkAnchorGrowthOverflow.t.sol`). It said: `amountOut
        // <= held` is enforced above, so the added term is at most `anchor` and
        // the sum at most twice it — "and doubling it needs a take of the WHOLE
        // remaining lot, and that take ends the lot."
        //
        // Both halves are true of the CALL and neither is true of the LOT.
        // `held` is not stored: it is `balanceOf(address(this))`, re-read live
        // at the top of every take, so anyone may put the asset back before the
        // next one. `_pricesThisLot` keeps the SAME descent over a band, and
        // `lot.offered` below only ever ratchets DOWN, which widens it — so a
        // take followed by a refill does not end the lot, and `open` keeps
        // answering `AlreadyOpened`. Refill by half and take the half back:
        // `amountOut/held` is `1/3`, the anchor grows by `4/3` a round, and
        // **154 rounds put it past `2^255`** (measured) for 154 wei of platform
        // coin, the asset coming straight back out each round. The 155th
        // panicked here, and from then on no take above about six per cent of
        // the lot could be served at all: 94% of the platform's inventory was
        // beyond every buyer, with `open` still refusing to start again.
        //
        // A bound argued from one call's arguments is not a bound over a
        // SEQUENCE of calls. So the bound this comment claimed is now enforced
        // rather than argued, and drawn where no honest sale can reach it:
        // `ANCHOR_CEILING` is `2^32` times the price every descent opens at,
        // which is more than the platform coin's whole supply can pay for a
        // hundredth of a raw unit. See its docstring for why the bound cannot
        // come from the sale arithmetic — growth COMPOUNDS down a shrinking lot
        // with no refill at all, and v1.6.2's own witness asserts 129x of it.
        //
        // The overflow is gone by induction, in one line: `open` sets `anchor =
        // 2^192 <= ANCHOR_CEILING`, the clamp restores `anchor <= ANCHOR_CEILING`
        // after every take, and `amountOut <= held` makes the added term at most
        // `anchor` — so the sum before the clamp is at most `2^225`, thirty-one
        // orders of magnitude short of a word.
        //
        // The ceiling is the OVERFLOW backstop and stays one whatever else
        // changes: it is the only thing standing between this addition and a
        // panic, and it does not depend on the growth term being well chosen.
        // The residual it used to leave — a 78-round, 78-wei pump to the ceiling
        // with 32 hours of halving to undo it — is closed below, by measuring
        // the sale against the lot instead of against the balance.
        uint64 frozenNow = guardian.frozenSeconds();
        // Only `open` sets the size a descent prices; a take may lower it and
        // never raise it. Raising it here let a caller ratchet the reference
        // size up inside one transaction — donate almost the lot, buy one unit
        // at the clamp, repeat — and then buy a real fee release against a size
        // that no descent ever priced (round 1 H1, both lenses).
        uint256 priced = lot.offered;
        uint256 remaining = Math.min(priced, held - amountOut);
        lot.offered = remaining;
        // **A sale moves the curve by what it took OUT OF THE LOT THIS DESCENT
        // PRICED, and by nothing else** (v1.6.20, closing the residual `HK19`'s
        // ceiling left behind).
        //
        // `amountOut / held` was the share of the BALANCE the sale carried away,
        // and the balance is not the lot: anyone may add to it. Units a caller
        // puts in and takes straight back out are not a sale of anything — the
        // platform ends up holding exactly what it held — yet they moved the
        // curve as if a third of the lot had gone, 78 rounds walking the anchor
        // to `ANCHOR_CEILING` for 78 wei, with 32 hours of halving needed to
        // bring it back. `priced - remaining` is what the LOT lost, so recycled
        // inventory now scores exactly zero and the pump has nothing to push.
        //
        // **This is deliberately not the change the v1.6.19 anchor proposed.**
        // That one was to tighten `_pricesThisLot`'s band so a lot which grew at
        // all stopped being priced by its descent. It is worse, and the reason is
        // worth keeping: the band's upper tolerance is what stops a ONE WEI
        // donation from making `_price` fall back to the start price. Tightening
        // it to equality would have traded a 78-round pump for an instant,
        // one-wei price reset that anybody could repeat — a cheaper attack than
        // the one being closed, and on the published price rather than on the
        // anchor. The band is left exactly as it was.
        //
        // Nothing on the honest path changes, which is why every witness below
        // `FeastPackageTwo` still reads the same numbers: inside the band the
        // sink's own writes leave `held == offered`, so `priced - remaining` IS
        // `amountOut` and this is the identical arithmetic. It differs only when
        // `held > offered`, and only ever downward.
        //
        // `priced == 0` is a lot no descent prices — `open` sets `offered` to a
        // non-zero balance, and only a whole-lot take drives it to zero. There is
        // no share to be a share OF, so the curve does not move and the anchor
        // waits for the `open` that must come before this lot is priced again.
        if (priced != 0) {
            lot.anchor =
                Math.min(lot.anchor + Math.mulDiv(lot.anchor, priced - remaining, priced), ANCHOR_CEILING);
        }
        // Weighted by the share this sale took, the way the anchor above already
        // is: a sale of the whole lot says what the whole lot was worth and
        // seeds the floor at its price, while one raw unit bought at the start
        // price says almost nothing and seeds almost nothing. Before this, a
        // single unit taken from a refilled lot at 2^192 pinned the floor 2^58
        // above parity for the fifty-eight days its own halving needed to come
        // down (round 4).
        //
        // **A take may raise the standing floor, never lower it, and never
        // restarts a clock it did not raise** (v1.6.3, `CA-b229a31396`). The
        // weighting of round 4 runs one way only: it stops dust RAISING a floor
        // and did nothing to stop dust ERASING one, so one wei of platform coin
        // bought away the floor a real sale had set and sent the remainder back
        // to halving hourly. Both sides of the comparison are the EFFECTIVE
        // floor — after the `SINK_FLOOR_HALVINGS` shift — so like is compared
        // with like; when the sale does not beat what is standing, neither the
        // base nor the clock is touched and the curve the earlier sale started
        // continues undisturbed.
        //
        // What that costs, stated: the floor a sale actually set is held
        // exactly, on its own clock. A later, LOWER sale's own-clock floor is
        // held to within the decay curve's chord gap — the decay is linear
        // inside each half-life, so `d(a+b) ≤ d(a)·d(b)`, and the worst case is
        // `9/8` at half a half-life on each clock, i.e. never worse than 8/9 of
        // it — **less an absolute slack of four raw price units**.
        //
        // The slack is not decoration and it is not a small-number artefact. The
        // 8/9 derivation is about real numbers; `_floorNow` shifts down and then
        // floors one linear step, and the promise is read the same way, so two
        // readings truncate twice each. At `a = b` of exactly half a half-life
        // the real inequality is TIGHT — the ratio is 9/8 — so those truncations
        // push it over at every magnitude, not only at small ones (v1.6.3 round
        // 1, `r1v`, which found the unqualified claim false and this pass's own
        // witness unable to fail). Where four units matter the relative half
        // says nothing and the slack is the whole promise.
        //
        // What four units is worth: a take pays `amountOut × price / 2^128`, so
        // four Q128 units over a lot of `N` raw units is up to `4N / 2^128`
        // platform coin. Per raw unit that is nothing; over an enormous lot it
        // is thousands of FEAST, and calling it "economically zero" was wrong
        // (round 3, `r3v`). It is the price of reading a decaying floor with
        // integer arithmetic, stated rather than dressed up.
        //
        // Witnesses: `testFuzz_theChordGapIsNeverWorseThanEightNinthsLessItsSlack`
        // (log-uniform over the whole domain, so it can reach the magnitudes
        // where the claim is weakest), `test_theChordGapNeedsItsAbsoluteSlackAtEveryMagnitude`,
        // and `test_theLensSequenceHoldsUnderTheRestatedClauseAndNotTheOldOne`.
        uint256 sold = Math.mulDiv(price, amountOut, held);
        if ((sold >> FeastGenesis.SINK_FLOOR_HALVINGS) > _floorNow(lot)) {
            lot.floorBase = sold;
            lot.lastSaleAt = uint64(block.timestamp);
            // The floor's own frozen checkpoint, written in the same branch as
            // its own clock. Not `frozenAtAnchor`: that one is written when a
            // descent is anchored, so the two checkpoints belong to different
            // instants.
            lot.frozenAtSale = frozenNow;
        }

        platformCoin.safeTransferFrom(msg.sender, address(this), cost);
        IFeastBurnableCoin(address(platformCoin)).burn(cost);
        emit Taken(asset, msg.sender, amountOut, cost, price);
        IERC20(asset).safeTransfer(msg.sender, amountOut);
    }

    /// @notice Burn any platform coin held here — it is never for sale.
    function burnStray() external nonReentrant {
        _requireUnfrozen();
        uint256 amount = platformCoin.balanceOf(address(this));
        emit StrayBurned(amount);
        if (amount != 0) IFeastBurnableCoin(address(platformCoin)).burn(amount);
    }

    function lot(address asset) external view returns (Lot memory) {
        return _lots[asset];
    }
}
