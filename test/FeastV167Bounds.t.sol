// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastConstants} from "../src/FeastConstants.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastOracle} from "../src/FeastOracle.sol";
import {FeastHook} from "../src/FeastHook.sol";
import {FeastPricer} from "../src/FeastPricer.sol";
import {PoolId} from "../src/venue/PoolId.sol";

import {FeastGuardian} from "../src/FeastGuardian.sol";
/// The v1.6.7 witnesses: the pre-launch branch of `settle`, which the v1.6.6 pack's MEDIUM moved
/// to the top of the decision.
///
/// The fix keyed the first-week rule on the LAUNCH STATE, as the contract's docstring has said
/// since round 4 H1. That moved three behaviours into one branch, and only one of them had a
/// witness. The mutation sweep said so: deleting the pre-launch `Moved` refusal survived, which
/// is the tool reporting a missing test rather than a passing gate.
///
/// So all three are pinned here, on a stub fixture that can drive the platform status and the
/// launch state independently — which the real fixture cannot, because before the pool opens
/// nobody but the launch window can move the platform price at all.
contract FeastV167PreLaunchTest is Test {
    FeastGuardian internal guardian = new FeastGuardian(address(0x3517), address(this));
    uint256 internal constant ONE = 1 << 128;
    uint256 internal constant FIRST_WEEK = 2_960;
    address internal constant QUOTE = address(0xBEEF);
    uint80 internal constant PAID = 1_000e18;

    V167StubLedger internal ledger;
    V167StubPricer internal pricer;
    V167StubHook internal hook;
    FeastEmissions internal emissions;

    function setUp() public {
        ledger = new V167StubLedger();
        pricer = new V167StubPricer();
        hook = new V167StubHook();
        ledger.setTotals(FIRST_WEEK, QUOTE, FeastFeeLedger.Credit({paid: PAID, earned: 0, referred: 0}));
        pricer.setQuote(QUOTE, FeastPricer.Status.Ok, ONE);
        emissions = new FeastEmissions(
            address(ledger), address(hook), address(0), PoolId.wrap(bytes32(0)), address(this), address(pricer), FIRST_WEEK,
            address(guardian)
        );
        vm.warp(ledger.weekStart(FIRST_WEEK + 1) + 1);
    }

    /// Before the pool opens, a platform price that HAS MOVED still waits out the pricing grace.
    /// This is the refusal the mutation sweep found unwitnessed: it predates the v1.6.7 fix and
    /// the fix carried it into the new branch, where nothing was checking that it survived.
    ///
    /// Kills: deleting the `Moved && !graceOver` refusal from the pre-launch branch.
    function test_beforeLaunchAMovedPlatformPriceWaitsOutTheGrace() public {
        hook.setOpen(false);
        pricer.setPlatform(FeastPricer.Status.Moved, 0);
        assertFalse(emissions.claimsOpen(), "the pool has not opened");

        vm.expectRevert(FeastEmissions.PlatformPriceMoved.selector);
        emissions.settle(1);
        assertEq(emissions.settledCount(), 0, "nothing settled, so the week can be retried");
    }

    /// And past the grace the same moved price settles under the first-week rule, because before
    /// launch the price is not what the cap is made of. The pair straddles the grace.
    function test_pastTheGraceTheSameMovedPriceSettlesUnderTheTokenCap() public {
        hook.setOpen(false);
        pricer.setPlatform(FeastPricer.Status.Moved, 0);
        vm.warp(ledger.weekStart(FIRST_WEEK + 1) + FeastGenesis.PRICING_GRACE + 1);

        emissions.settle(1);

        FeastEmissions.Week memory w = emissions.weekInfo(1);
        assertTrue(w.tokenCapOnly, "the first-week rule");
        assertEq(
            w.pot[emissions.TRADER()],
            emissions.tokenCap(1) * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS,
            "at the token cap, not at a price"
        );
    }

    /// The finding itself, at the unit level: before the pool opens, an `Ok` price does NOT bring
    /// the value cap with it. `test/audit/poc/EmissionsPreLaunchValueCap.t.sol` proves the same
    /// thing through the real launch window; this one pins the branch directly.
    ///
    /// Kills: asking the price before asking the launch state.
    function test_beforeLaunchAnOkPriceDoesNotBringTheValueCap() public {
        hook.setOpen(false);
        // A price so small the value cap would be far below the token cap, so the two are
        // impossible to confuse: under the old ordering this week emitted the value cap.
        pricer.setPlatform(FeastPricer.Status.Ok, 1);

        emissions.settle(1);

        FeastEmissions.Week memory w = emissions.weekInfo(1);
        assertTrue(w.tokenCapOnly, "a vouched price before launch changes nothing");
        assertEq(
            w.pot[emissions.TRADER()],
            emissions.tokenCap(1) * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS,
            "the full token-cap share"
        );
    }

    /// The control: the SAME `Ok` price, with the pool open, does bring the value cap. So the
    /// branch turns on the launch state and on nothing else.
    function test_afterLaunchTheSameOkPriceDoesBringTheValueCap() public {
        hook.setOpen(true);
        pricer.setPlatform(FeastPricer.Status.Ok, 1);

        emissions.settle(1);

        FeastEmissions.Week memory w = emissions.weekInfo(1);
        assertFalse(w.tokenCapOnly, "after launch the value cap binds");
        assertLt(
            w.pot[emissions.TRADER()],
            emissions.tokenCap(1) * FeastGenesis.EARLY_TRADER_BPS / FeastGenesis.BPS,
            "and it binds far below the token cap"
        );
    }
}

/// The oracle's own promise, which said "never below the floor" while flooring only the history.
contract FeastV167OracleWindowTest is Test {
    FeastOracle internal oracle;
    PoolId internal id = PoolId.wrap(bytes32(uint256(7)));

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new FeastOracle(address(this));
    }

    /// The codex units' own construction: tick 0 at T, tick 10 000 at T+600, then ask for a
    /// one-second average at T+601. Before the fix that returned 10 000 — a spot reading wearing
    /// an average's name. Now every window is at least `MIN_OBSERVATION_AGE`, so the short ask
    /// and the floor ask agree.
    ///
    /// Kills: dropping the clamp (the one-second ask returns the last tick).
    function test_aShortWindowIsRaisedToTheFloorRatherThanAnswered() public {
        oracle.write(id, int24(0));
        vm.warp(block.timestamp + 600);
        oracle.write(id, int24(10_000));
        vm.warp(block.timestamp + 1);

        int24 atFloor = oracle.consult(id, FeastConstants.MIN_OBSERVATION_AGE);
        int24 asked = oracle.consult(id, 1);
        assertEq(asked, atFloor, "a one-second ask is answered at the floor");
        assertLt(asked, int24(10_000), "and so is not the last second's tick");
    }

    /// The control: a window ABOVE the floor is still honoured as asked, so the clamp raises the
    /// short ones and touches nothing else.
    function test_aWindowAboveTheFloorIsStillUsedAsAsked() public {
        oracle.write(id, int24(0));
        vm.warp(block.timestamp + 1_200);
        oracle.write(id, int24(10_000));
        vm.warp(block.timestamp + 600);

        assertTrue(oracle.consult(id, 600) != oracle.consult(id, 1_800), "different windows, different answers");
    }
}

contract V167StubLedger {
    mapping(uint256 => mapping(address => FeastFeeLedger.Credit)) internal _totals;

    function setTotals(uint256 week, address quote, FeastFeeLedger.Credit memory c) external {
        _totals[week][quote] = c;
    }

    function totals(uint256 week, address quote) external view returns (FeastFeeLedger.Credit memory) {
        return _totals[week][quote];
    }

    function weekStart(uint256 week) public pure returns (uint256) {
        return week * FeastGenesis.WEEK_LENGTH - FeastGenesis.WEEK_ALIGNMENT;
    }

    function currentWeek() external view returns (uint256) {
        return (block.timestamp + FeastGenesis.WEEK_ALIGNMENT) / FeastGenesis.WEEK_LENGTH;
    }
}

contract V167StubPricer {
    address[] internal _quotes;
    mapping(address => FeastPricer.Status) internal _status;
    mapping(address => uint256) internal _price;
    FeastPricer.Status internal _platformStatus;
    uint256 internal _platformPrice;

    function setQuote(address quote, FeastPricer.Status s, uint256 p) external {
        _quotes.push(quote);
        _status[quote] = s;
        _price[quote] = p;
    }

    function setPlatform(FeastPricer.Status s, uint256 p) external {
        _platformStatus = s;
        _platformPrice = p;
    }

    function quotes() external view returns (address[] memory) {
        return _quotes;
    }

    function priceQ128(address quote) external view returns (FeastPricer.Status, uint256) {
        return (_status[quote], _price[quote]);
    }

    function platformPerNativeQ128() external view returns (FeastPricer.Status, uint256) {
        return (_platformStatus, _platformPrice);
    }
}

/// The launch state, settable — which is the whole point of this fixture.
contract V167StubHook {
    bool internal _open;

    function setOpen(bool v) external {
        _open = v;
    }

    function poolInfo(PoolId) external view returns (FeastHook.Pool memory p) {
        if (_open) {
            p.coin = address(0xC01B);
            p.openAt = uint64(block.timestamp);
        }
    }
}
