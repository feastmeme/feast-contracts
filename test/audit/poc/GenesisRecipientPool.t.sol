// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastEmissions} from "../../../src/FeastEmissions.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastGenesisGrants} from "../../../src/FeastGenesisGrants.sol";
import {FeastGuardian} from "../../../src/FeastGuardian.sol";
import {FeastPlatformSink} from "../../../src/FeastPlatformSink.sol";
import {PoolId} from "../../../src/venue/PoolId.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// **`genesis-recipient-pool-unchecked`** — `CA-c03b8b2ead`, `P4-claude` LOW,
/// v1.6.20 round, at `src/FeastFactory.sol:436`.
///
/// Genesis asks emissions its role and its coin, never `platformPoolId()`.
/// Every exit of the 14.2% — `claim`, `releaseRedirect`, `burnRemainder`, and
/// `burnExpired` through `expiryOf` — waits on `claimsOpen()`, which reads
/// `hook.poolInfo(platformPoolId)`, so an emissions keyed to another pool never
/// opens and its allocation has no way out. The same gate reads the emissions'
/// `hook()`, so that is asked too; and the grants contract reads `claimsOpen()`
/// and `settledCount()` from its own `emissions()` pointer, so genesis asks that
/// pointer as well — the 0.8% half of the finding's own title.
///
/// Every witness runs genesis through a low-level call. Where it is ADMITTED —
/// which is what the tag does — the harm is measured and logged before the
/// assertion fails; where it is refused, the refusal must be the named one.
///
/// Measured at `v1.6.21-audit` (`e5c0a77`): all three admitted. The emissions
/// keyed to `PoolId(1)` took `142_000_000e18`, and after the window settled and
/// the pool opened, `claimsOpen()` still read `false`.
contract GenesisRecipientPoolTest is UnitFixture {
    function _sixOfEight() internal pure returns (address[8] memory six) {
        for (uint256 i = 0; i < 6; i++) six[i] = address(uint160(0xBB00 + i));
    }

    function _emissions(address hook_, PoolId poolId, address guardian_) internal returns (FeastEmissions) {
        return new FeastEmissions(
            address(ledger), hook_, feast, poolId, address(timelock), address(pricer), ledger.weekOf(OPENING), guardian_
        );
    }

    /// The fixture's own ceremony, up to the genesis call: the day before the
    /// window, the sink armed.
    function _ready() internal returns (FeastFactory.GenesisParams memory p) {
        _warpTo(windowStart - 1 days);
        vm.prank(genesisKey);
        sink.schedule(address(window));
        p = _genesisParams();
    }

    function _genesisCall(FeastFactory.GenesisParams memory p) internal returns (bool ok, bytes memory ret) {
        vm.prank(genesisKey);
        (ok, ret) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));
    }

    /// The window settles and the pool opens, so every claim that can ever open
    /// has opened.
    function _launchAfterGenesis() internal {
        _warpTo(windowStart + 1);
        address committer = address(0xC0D1);
        vm.deal(committer, 10e18);
        vm.prank(committer);
        window.commit{value: 10e18}();
        _warpTo(window.endsAt());
        window.settle();
        _warpTo(window.endsAt() + 1 days);
    }

    // --- CA-c03b8b2ead: which pool the 14.2% (and the 0.8%) can ever leave by ---

    function test_genesisRefusesAnEmissionsKeyedToAnotherPool() public {
        FeastFactory.GenesisParams memory p = _ready();
        PoolId elsewhere = PoolId.wrap(bytes32(uint256(1)));
        FeastEmissions wrong = _emissions(address(hook), elsewhere, address(guardian));
        // The grants contract reads the emissions it was built with, so it is
        // built with this one: the question here is the POOL, and only the pool.
        p.emissions = address(wrong);
        p.grants = address(new FeastGenesisGrants(feast, address(wrong), TARGET, partnerList, address(guardian)));

        (bool ok, bytes memory ret) = _genesisCall(p);
        if (ok) {
            console2.log("emissions held      :", IERC20(feast).balanceOf(address(wrong)));
            _launchAfterGenesis();
            console2.log("claimsOpen, opened  :", wrong.claimsOpen());
        }
        assertFalse(ok, "genesis paid 14.2% to an emissions keyed to another pool");
        assertEq(
            ret,
            abi.encodeWithSignature("EmissionsPoolMismatch(bytes32,bytes32)", elsewhere, feastPoolId),
            "refused by name, naming both pools"
        );
    }

    /// The same gate, read through the other half of it: `claimsOpen()` asks
    /// `hook.poolInfo`, so an emissions that asks another hook never opens
    /// either.
    function test_genesisRefusesAnEmissionsThatAsksAnotherHook() public {
        FeastFactory.GenesisParams memory p = _ready();
        address otherHook = address(0x400C);
        FeastEmissions wrong = _emissions(otherHook, feastPoolId, address(guardian));
        p.emissions = address(wrong);
        p.grants = address(new FeastGenesisGrants(feast, address(wrong), TARGET, partnerList, address(guardian)));

        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid 14.2% to an emissions that reads another hook");
        assertEq(ret, abi.encodeWithSignature("EmissionsHookMismatch(address,address)", otherHook, address(hook)));
    }

    /// The 0.8% half of the finding: a grants contract whose `emissions` is not
    /// the emissions genesis pays waits on a `claimsOpen()` and a
    /// `settledCount()` that are not this platform's.
    function test_genesisRefusesAGrantsContractReadingAnotherEmissions() public {
        FeastFactory.GenesisParams memory p = _ready();
        FeastEmissions sibling = _emissions(address(hook), feastPoolId, address(guardian));
        p.grants = address(new FeastGenesisGrants(feast, address(sibling), TARGET, partnerList, address(guardian)));

        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid 0.8% to grants that read another emissions");
        assertEq(
            ret, abi.encodeWithSignature("GrantsEmissionsMismatch(address,address)", address(sibling), address(emissions))
        );
    }

    /// The control: the fixture's own recipients pass every question, so the
    /// refusals above are about the wiring they name and not about the fixture.
    function test_theFixturesOwnRecipientsPassEveryQuestion() public {
        (bool ok,) = _genesisCall(_ready());
        assertTrue(ok, "the honest ceremony is admitted");
    }
}
