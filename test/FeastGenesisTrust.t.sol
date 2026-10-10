// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastEmissions} from "../src/FeastEmissions.sol";
import {FeastFactory, IFeastGenesisQuestions} from "../src/FeastFactory.sol";
import {FeastFeeLedger} from "../src/FeastFeeLedger.sol";
import {FeastGenesis} from "../src/FeastGenesis.sol";
import {FeastGenesisGrants} from "../src/FeastGenesisGrants.sol";
import {FeastLaunchWindow} from "../src/FeastLaunchWindow.sol";
import {FeastPlatformSink} from "../src/FeastPlatformSink.sol";
import {FeastTeamVesting} from "../src/FeastTeamVesting.sol";
import {IFeastGenesisRecipient} from "../src/IFeastGenesisRecipient.sol";
import {PoolId} from "../src/venue/PoolId.sol";

import {UnitFixture} from "./utils/UnitFixture.sol";

// How a `Liar` answers the one question it lies about.
uint8 constant LIE_WORD = 0; // one word: the word it was given
uint8 constant LIE_REVERTS = 1; // no answer: the call reverts
uint8 constant LIE_EMPTY = 2; // a call that succeeds and returns nothing
uint8 constant LIE_LONGER = 3; // two words: the word it was given, twice
uint8 constant LIE_SHORT = 4; // 31 bytes: less than a word

/// @dev Reads the factory's question table and nothing else. Test-only: it
///      inherits the factory to reach `_questions`, and is never given a genesis.
contract FactoryTable is FeastFactory {
    constructor(
        address poolManager_,
        address vault_,
        address hook_,
        address vesting_,
        address platformTokenDeployer_,
        address wrappedNative_,
        address genesisKey_
    ) FeastFactory(poolManager_, vault_, hook_, vesting_, platformTokenDeployer_, wrappedNative_, genesisKey_) {}

    function questions(bytes32 role) external pure returns (uint256[] memory) {
        return _questions(role);
    }
}

/// @dev A recipient that answers every question exactly as a genuine one does —
///      it forwards them — except ONE getter, which it answers as `mode` says.
contract Liar {
    address internal immutable genuine;
    bytes4 internal immutable lieAbout;
    uint8 internal immutable mode;
    bytes32 internal immutable word;

    constructor(address genuine_, bytes4 lieAbout_, uint8 mode_, bytes32 word_) {
        genuine = genuine_;
        lieAbout = lieAbout_;
        mode = mode_;
        word = word_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sig == lieAbout) {
            if (mode == LIE_WORD) return abi.encode(word);
            if (mode == LIE_REVERTS) revert("the liar will not say");
            if (mode == LIE_EMPTY) return "";
            if (mode == LIE_LONGER) return abi.encode(word, word);
            return new bytes(31);
        }
        (bool ok, bytes memory ret) = genuine.staticcall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

/// **v1.6.22: genesis asserts the full set, once** (owner ruling, 2026-09-25).
///
/// Five times a recipient answered every question genesis asked and was still
/// built against the wrong thing — the window's key, the team wallet's
/// guardian, the sink's arming (closed one by one in v1.6.21), then the grants
/// contract's guardian and the window's factory (Codex appendix on
/// `v1.6.21-audit`, HIGH each). v1.6.22 closes the shape rather than the rows:
/// one path, `_requireTrusted`, through which every recipient passes, asking
/// the whole of one table, `_questions`.
///
/// What is held here, in order:
///   - the table is the one that was reviewed, row for row, and its getters are
///     the recipients' own selectors;
///   - every one of its 18 questions, answered wrongly or not at all, refuses
///     genesis by that question's own name, naming both answers;
///   - the engine reads an answer by its length, to the bit;
///   - nothing genesis pays, calls or stores is reached before it has been
///     asked everything — derived from what genesis actually does, not listed;
///   - the questions no witness drives are driven with genuine contracts.
contract FeastGenesisTrustTest is UnitFixture {
    /// One reviewed question: who is asked, what, which error refuses any other
    /// answer, and the answer this deployment's genuine recipient gives —
    /// written here from the fixture and from the published figures, never
    /// read back from the factory.
    struct Question {
        bytes32 role;
        bytes4 getter;
        bytes4 refusal;
        bytes32 expected;
    }

    FactoryTable internal table;

    function setUp() public override {
        super.setUp();
        table = new FactoryTable(
            address(pm), address(vault), address(hook), address(vesting), address(tokenDeployer), address(wbnb), genesisKey
        );
        // The ceremony as `script/Genesis.s.sol` runs it: the day before the
        // window, with the sink armed first.
        _warpTo(windowStart - 1 days);
        vm.prank(genesisKey);
        sink.schedule(address(window));
    }

    // --- the table ----------------------------------------------------------

    function _w(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev The table as reviewed at the plan stop (`.runs/plan-656.md` §2), in
    ///      the order the factory asks it.
    function _reviewed() internal view returns (Question[] memory t) {
        bytes32 W = FeastGenesis.ROLE_LAUNCH_WINDOW;
        bytes32 T = FeastGenesis.ROLE_TEAM_VESTING;
        bytes32 E = FeastGenesis.ROLE_EMISSIONS;
        bytes32 G = FeastGenesis.ROLE_GRANTS;
        bytes32 S = FeastGenesis.ROLE_PLATFORM_SINK;
        bytes32 close = bytes32(uint256(window.endsAt()));
        t = new Question[](18);
        t[0] = Question(W, FeastLaunchWindow.poolKey.selector, FeastFactory.WindowPoolKeyMismatch.selector, PoolId.unwrap(feastPoolId));
        t[1] = Question(W, window.factory.selector, FeastFactory.WindowFactoryMismatch.selector, _w(address(factory)));
        t[2] = Question(W, window.hook.selector, FeastFactory.WindowHookMismatch.selector, _w(address(hook)));
        t[3] = Question(W, window.poolManager.selector, FeastFactory.WindowPoolManagerMismatch.selector, _w(address(pm)));
        t[4] = Question(W, window.wrappedNative.selector, FeastFactory.WindowWrappedNativeMismatch.selector, _w(address(wbnb)));
        t[5] = Question(T, teamVesting.start.selector, FeastFactory.TeamVestingStartNotWindowClose.selector, close);
        t[6] = Question(T, teamVesting.guardian.selector, FeastFactory.TeamVestingGuardianMismatch.selector, _w(address(guardian)));
        // 36 months of 30.4375 days (owner, 2026-09-11).
        t[7] = Question(T, teamVesting.duration.selector, FeastFactory.TeamVestingDurationMismatch.selector, bytes32(uint256(94_672_800)));
        t[8] = Question(E, emissions.guardian.selector, FeastFactory.EmissionsGuardianMismatch.selector, _w(address(guardian)));
        t[9] = Question(E, emissions.hook.selector, FeastFactory.EmissionsHookMismatch.selector, _w(address(hook)));
        t[10] = Question(E, emissions.platformPoolId.selector, FeastFactory.EmissionsPoolMismatch.selector, PoolId.unwrap(feastPoolId));
        t[11] = Question(E, emissions.ledger.selector, FeastFactory.EmissionsLedgerMismatch.selector, _w(address(ledger)));
        // 14.2% of the billion.
        t[12] = Question(E, emissions.budget.selector, FeastFactory.EmissionsBudgetMismatch.selector, bytes32(uint256(142_000_000e18)));
        t[13] = Question(G, grants.guardian.selector, FeastFactory.GrantsGuardianMismatch.selector, _w(address(guardian)));
        t[14] = Question(G, grants.emissions.selector, FeastFactory.GrantsEmissionsMismatch.selector, _w(address(emissions)));
        // 0.1% for each of eight partners.
        t[15] = Question(G, grants.grant.selector, FeastFactory.GrantsGrantMismatch.selector, bytes32(uint256(1_000_000e18)));
        t[16] = Question(S, sink.opensAt.selector, FeastFactory.SinkNotArmed.selector, close);
        t[17] = Question(S, sink.guardian.selector, FeastFactory.SinkGuardianMismatch.selector, _w(address(guardian)));
    }

    function _roles() internal pure returns (bytes32[5] memory) {
        return [
            FeastGenesis.ROLE_LAUNCH_WINDOW,
            FeastGenesis.ROLE_TEAM_VESTING,
            FeastGenesis.ROLE_EMISSIONS,
            FeastGenesis.ROLE_GRANTS,
            FeastGenesis.ROLE_PLATFORM_SINK
        ];
    }

    /// The factory asks exactly the reviewed questions, in the reviewed order,
    /// refused by the reviewed names — and a row is one question and nothing
    /// else. A row added, dropped, reordered or re-pointed fails here.
    function test_theTableIsTheReviewedTable() public view {
        Question[] memory t = _reviewed();
        bytes32[5] memory roles = _roles();
        uint256 k;
        for (uint256 r = 0; r < roles.length; r++) {
            uint256[] memory rows = table.questions(roles[r]);
            for (uint256 j = 0; j < rows.length; j++) {
                assertLt(k, t.length, "the factory asks more than was reviewed");
                assertEq(t[k].role, roles[r], "a question asked of the wrong recipient");
                assertEq(bytes4(uint32(rows[j] >> 40)), t[k].getter, "the question asked");
                assertEq(bytes4(uint32(rows[j] >> 8)), t[k].refusal, "the error it is refused with");
                assertLt(rows[j] & 0xff, 12, "a fact genesis holds");
                assertEq(rows[j] >> 72, 0, "nothing else in the word");
                k++;
            }
        }
        assertEq(k, t.length, "every reviewed question is asked, and no other");
    }

    /// The vocabulary genesis asks in is the recipients' own: every selector in
    /// `IFeastGenesisQuestions` is the selector of the getter that answers it,
    /// so a getter renamed in a recipient fails here, not at a ceremony.
    function test_theQuestionsAreTheRecipientsOwnSelectors() public view {
        assertEq(IFeastGenesisQuestions.poolKey.selector, FeastLaunchWindow.poolKey.selector, "poolKey");
        assertEq(IFeastGenesisQuestions.factory.selector, window.factory.selector, "factory");
        assertEq(IFeastGenesisQuestions.hook.selector, window.hook.selector, "window hook");
        assertEq(IFeastGenesisQuestions.hook.selector, emissions.hook.selector, "emissions hook");
        assertEq(IFeastGenesisQuestions.poolManager.selector, window.poolManager.selector, "poolManager");
        assertEq(IFeastGenesisQuestions.wrappedNative.selector, window.wrappedNative.selector, "wrappedNative");
        assertEq(IFeastGenesisQuestions.start.selector, teamVesting.start.selector, "start");
        assertEq(IFeastGenesisQuestions.duration.selector, teamVesting.duration.selector, "duration");
        assertEq(IFeastGenesisQuestions.platformPoolId.selector, emissions.platformPoolId.selector, "platformPoolId");
        assertEq(IFeastGenesisQuestions.ledger.selector, emissions.ledger.selector, "ledger");
        assertEq(IFeastGenesisQuestions.budget.selector, emissions.budget.selector, "budget");
        assertEq(IFeastGenesisQuestions.emissions.selector, grants.emissions.selector, "emissions");
        assertEq(IFeastGenesisQuestions.grant.selector, grants.grant.selector, "grant");
        assertEq(IFeastGenesisQuestions.opensAt.selector, sink.opensAt.selector, "opensAt");
        assertEq(IFeastGenesisQuestions.guardian.selector, teamVesting.guardian.selector, "team guardian");
        assertEq(IFeastGenesisQuestions.guardian.selector, emissions.guardian.selector, "emissions guardian");
        assertEq(IFeastGenesisQuestions.guardian.selector, grants.guardian.selector, "grants guardian");
        assertEq(IFeastGenesisQuestions.guardian.selector, sink.guardian.selector, "sink guardian");
    }

    // --- one property missing -> the named error ------------------------------

    function _genuine(bytes32 role) internal view returns (address) {
        if (role == FeastGenesis.ROLE_LAUNCH_WINDOW) return address(window);
        if (role == FeastGenesis.ROLE_TEAM_VESTING) return address(teamVesting);
        if (role == FeastGenesis.ROLE_EMISSIONS) return address(emissions);
        if (role == FeastGenesis.ROLE_GRANTS) return address(grants);
        return address(sink);
    }

    function _naming(FeastFactory.GenesisParams memory p, bytes32 role, address r)
        internal
        pure
        returns (FeastFactory.GenesisParams memory)
    {
        if (role == FeastGenesis.ROLE_LAUNCH_WINDOW) p.window = r;
        else if (role == FeastGenesis.ROLE_TEAM_VESTING) p.teamVesting = r;
        else if (role == FeastGenesis.ROLE_EMISSIONS) p.emissions = r;
        else if (role == FeastGenesis.ROLE_GRANTS) p.grants = r;
        else p.platformSink = r;
        return p;
    }

    function _genesisCall(FeastFactory.GenesisParams memory p) internal returns (bool ok, bytes memory ret) {
        vm.prank(genesisKey);
        (ok, ret) = address(factory).call(abi.encodeCall(FeastFactory.genesis, (p)));
    }

    /// Every question, answered wrongly by a recipient that answers every
    /// other question as the genuine one does: refused by that question's own
    /// error, naming what was answered and what was expected.
    function test_everyQuestionAnsweredWronglyIsRefusedByName() public {
        Question[] memory t = _reviewed();
        for (uint256 i = 0; i < t.length; i++) {
            bytes32 wrong = t[i].expected ^ bytes32(uint256(1));
            Liar liar = new Liar(_genuine(t[i].role), t[i].getter, LIE_WORD, wrong);
            (bool ok, bytes memory ret) = _genesisCall(_naming(_genesisParams(), t[i].role, address(liar)));
            assertFalse(ok, "genesis trusted a recipient that answered one question wrongly");
            assertEq(ret, abi.encodeWithSelector(t[i].refusal, wrong, t[i].expected), "refused by name");
        }
        assertFalse(factory.genesisDone(), "and nothing happened");
    }

    /// Every question, not answered at all: refused as if it had named zero —
    /// a contract that cannot answer is refused, never trusted.
    function test_everyQuestionLeftUnansweredIsRefusedByName() public {
        Question[] memory t = _reviewed();
        for (uint256 i = 0; i < t.length; i++) {
            Liar liar = new Liar(_genuine(t[i].role), t[i].getter, LIE_REVERTS, bytes32(0));
            (bool ok, bytes memory ret) = _genesisCall(_naming(_genesisParams(), t[i].role, address(liar)));
            assertFalse(ok, "genesis trusted a recipient that could not answer one question");
            assertEq(ret, abi.encodeWithSelector(t[i].refusal, bytes32(0), t[i].expected), "refused by name");
        }
        assertFalse(factory.genesisDone(), "and nothing happened");
    }

    /// **The engine, to the bit** (coordinator ruling on the plan). One row —
    /// the grants contract's guardian, the Codex appendix's own — and every
    /// shape an answer can take. The refusal is `selector ++ named ++ expected`,
    /// where `named` is: zero for a call that failed; the word, for a one-word
    /// answer; the `keccak256` of all of it, for a longer one (a pool key's six
    /// words hash to its `PoolId` this way); and zero again for a call that
    /// succeeded with less than a word, because that answered nothing.
    function test_theEngineReadsAnAnswerByItsLengthToTheBit() public {
        bytes4 refusal = FeastFactory.GrantsGuardianMismatch.selector;
        bytes32 expected = _w(address(guardian));
        bytes32 named = _w(address(0xBAD));

        _assertGrantsRefusal(LIE_REVERTS, named, abi.encodeWithSelector(refusal, bytes32(0), expected));
        _assertGrantsRefusal(LIE_WORD, named, abi.encodeWithSelector(refusal, named, expected));
        _assertGrantsRefusal(
            LIE_LONGER, named, abi.encodeWithSelector(refusal, keccak256(abi.encode(named, named)), expected)
        );
        _assertGrantsRefusal(LIE_EMPTY, named, abi.encodeWithSelector(refusal, bytes32(0), expected));
        _assertGrantsRefusal(LIE_SHORT, named, abi.encodeWithSelector(refusal, bytes32(0), expected));

        // And those bytes are exactly the Solidity error's own encoding, which
        // is what the witnesses compare against.
        assertEq(
            abi.encodeWithSelector(refusal, named, expected),
            abi.encodeWithSignature("GrantsGuardianMismatch(address,address)", address(0xBAD), address(guardian)),
            "the engine's refusal is the error's ABI encoding"
        );
    }

    function _assertGrantsRefusal(uint8 mode, bytes32 word, bytes memory expected) internal {
        Liar liar = new Liar(address(grants), grants.guardian.selector, mode, word);
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.grants = address(liar);
        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "refused");
        assertEq(ret, expected, "to the bit");
    }

    // --- nothing is reached before it is asked --------------------------------

    function _selector(bytes memory data) internal pure returns (bytes4) {
        return bytes4(data);
    }

    /// @dev The first ABI argument of a call, as an address.
    function _firstArgument(bytes memory data) internal pure returns (address a) {
        if (data.length < 36) return address(0);
        assembly ("memory-safe") {
            a := and(mload(add(data, 36)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _own(address c) internal view returns (bool) {
        return c == address(factory) || c == address(hook) || c == address(guardian) || c == address(tokenDeployer)
            || c == address(pm) || c == address(vault) || c == address(wbnb) || c == address(vesting) || c == feast
            || c == address(ledger) || c == address(oracle) || c == address(this) || c == address(vm);
    }

    function _has(address[] memory set, uint256 n, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < n; i++) {
            if (set[i] == a) return true;
        }
        return false;
    }

    function _add(address[] memory set, uint256 n, address a) internal pure returns (uint256) {
        if (_has(set, n, a)) return n;
        set[n] = a;
        return n + 1;
    }

    /// @dev Does this word hold `a`'s address at any byte offset a packed slot
    ///      could put it at?
    function _holds(bytes32 word, address a) internal pure returns (bool) {
        for (uint256 shift = 0; shift <= 96; shift += 8) {
            if (address(uint160(uint256(word) >> shift)) == a) return true;
        }
        return false;
    }

    function _isTransferTo(Vm.AccountAccess memory x, address to) internal view returns (bool) {
        return x.kind == VmSafe.AccountAccessKind.Call && x.accessor == address(factory) && x.account == feast
            && _selector(x.data) == IERC20.transfer.selector && _firstArgument(x.data) == to;
    }

    /// @dev The first access at which genesis RELIES on `r`: pays it, calls it
    ///      with the power to change state, or writes its address into any
    ///      storage. `a.length` if never.
    function _firstReach(Vm.AccountAccess[] memory a, address r) internal view returns (uint256) {
        for (uint256 i = 0; i < a.length; i++) {
            if (_isTransferTo(a[i], r)) return i;
            if (a[i].kind == VmSafe.AccountAccessKind.Call && a[i].accessor == address(factory) && a[i].account == r) {
                return i;
            }
            for (uint256 j = 0; j < a[i].storageAccesses.length; j++) {
                Vm.StorageAccess memory s = a[i].storageAccesses[j];
                if (s.isWrite && !s.reverted && _holds(s.newValue, r)) return i;
            }
        }
        return a.length;
    }

    function _askedBefore(Vm.AccountAccess[] memory a, address r, bytes4 question, uint256 before)
        internal
        view
        returns (bool)
    {
        for (uint256 i = 0; i < before; i++) {
            if (
                a[i].kind == VmSafe.AccountAccessKind.StaticCall && a[i].accessor == address(factory)
                    && a[i].account == r && _selector(a[i].data) == question
            ) return true;
        }
        return false;
    }

    /// **A new recipient cannot bypass the path** (coordinator ruling on the
    /// plan). The honest ceremony runs under state-diff recording, and the set
    /// of contracts genesis trusts is DERIVED from what it did — every contract
    /// the factory pays platform coin to, every contract it calls that is not
    /// one of its own, and every contract whose address it writes into any
    /// storage — not listed. That set must be exactly the five genesis names,
    /// and each of them must have been asked its role, its coin and every
    /// question `_questions` holds for that role BEFORE genesis first relied on
    /// it. A sixth recipient added to genesis without a row fails the first
    /// assertion; one paid, called or stored before it is asked fails the rest.
    ///
    /// Residue, stated: an address genesis hands to another contract that
    /// neither pays nor calls it, and stores it only inside a mapping KEY or
    /// transformed, is invisible to this trace.
    function test_everyContractGenesisPaysCallsOrStoresWasAskedFirst() public {
        FeastFactory.GenesisParams memory p = _genesisParams();
        vm.startStateDiffRecording();
        vm.prank(genesisKey);
        factory.genesis(p);
        Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();

        address[] memory trusted = new address[](32);
        uint256 n;
        for (uint256 i = 0; i < a.length; i++) {
            Vm.AccountAccess memory x = a[i];
            // Paid: a platform-coin transfer the factory makes.
            if (
                x.kind == VmSafe.AccountAccessKind.Call && x.accessor == address(factory) && x.account == feast
                    && _selector(x.data) == IERC20.transfer.selector
            ) n = _add(trusted, n, _firstArgument(x.data));
            // Called: anything the factory calls that is not its own.
            if (
                (x.kind == VmSafe.AccountAccessKind.Call || x.kind == VmSafe.AccountAccessKind.StaticCall)
                    && x.accessor == address(factory) && !_own(x.account)
            ) n = _add(trusted, n, x.account);
            // Stored: any contract's address, at any packed offset, in any
            // storage genesis writes.
            for (uint256 j = 0; j < x.storageAccesses.length; j++) {
                Vm.StorageAccess memory s = x.storageAccesses[j];
                if (!s.isWrite || s.reverted) continue;
                for (uint256 shift = 0; shift <= 96; shift += 8) {
                    address c = address(uint160(uint256(s.newValue) >> shift));
                    if (c.code.length != 0 && !_own(c)) n = _add(trusted, n, c);
                }
            }
        }

        assertEq(n, 5, "genesis relies on a contract beyond the five it names: give it a row in `_questions`");
        address[5] memory named = [address(window), address(teamVesting), address(emissions), address(grants), address(sink)];
        for (uint256 k = 0; k < named.length; k++) {
            assertTrue(_has(trusted, n, named[k]), "each named recipient is one genesis relies on");
        }

        for (uint256 k = 0; k < n; k++) {
            address r = trusted[k];
            uint256 first = _firstReach(a, r);
            assertLt(first, a.length, "genesis relies on it somewhere");
            assertTrue(_askedBefore(a, r, IFeastGenesisRecipient.genesisRole.selector, first), "asked its role first");
            assertTrue(_askedBefore(a, r, IFeastGenesisRecipient.platformCoin.selector, first), "asked its coin first");
            uint256[] memory rows = table.questions(IFeastGenesisRecipient(r).genesisRole());
            assertGt(rows.length, 0, "every role has questions");
            for (uint256 j = 0; j < rows.length; j++) {
                assertTrue(
                    _askedBefore(a, r, bytes4(uint32(rows[j] >> 40)), first),
                    "asked every question of its role before genesis relied on it"
                );
            }
        }
    }

    // --- the questions no witness drives, with genuine contracts ----------------

    function _windowWiredTo(address hook_, address poolManager_, address wrappedNative_)
        internal
        returns (FeastLaunchWindow)
    {
        return new FeastLaunchWindow(
            wrappedNative_, feast, address(vault), poolManager_, hook_, address(factory), feastKey, uint64(windowStart)
        );
    }

    /// A window whose gate is read from another hook can never settle: its
    /// `_canSettle` asks a pool nobody registered there.
    function test_aWindowReadingAnotherHookIsRefused() public {
        address other = address(0x400C);
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.window = address(_windowWiredTo(other, address(pm), address(wbnb)));
        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid 60% to a window that reads another hook");
        assertEq(ret, abi.encodeWithSelector(FeastFactory.WindowHookMismatch.selector, other, address(hook)));
    }

    /// A window that initialises through another pool manager seeds a pool
    /// that was never initialised here.
    function test_aWindowInitialisingThroughAnotherPoolManagerIsRefused() public {
        address other = address(0x9A9A);
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.window = address(_windowWiredTo(address(hook), other, address(wbnb)));
        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid 60% to a window that initialises elsewhere");
        assertEq(ret, abi.encodeWithSelector(FeastFactory.WindowPoolManagerMismatch.selector, other, address(pm)));
    }

    /// A window whose pot is in another token pays the hook in a token the
    /// pool cannot take, and every settlement with a commit reverts.
    function test_aWindowHoldingAnotherWrappedNativeIsRefused() public {
        address other = address(0x3B3B);
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.window = address(_windowWiredTo(address(hook), address(pm), other));
        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid 60% to a window that holds its pot in another token");
        assertEq(ret, abi.encodeWithSelector(FeastFactory.WindowWrappedNativeMismatch.selector, other, address(wbnb)));
    }

    /// An emissions reading another ledger settles against fees this platform
    /// never recorded — or, with nothing behind it, never settles at all.
    function test_anEmissionsReadingAnotherLedgerIsRefused() public {
        FeastFeeLedger other = new FeastFeeLedger(address(hook));
        FeastEmissions wrong = new FeastEmissions(
            address(other), address(hook), feast, feastPoolId, address(timelock), address(pricer), ledger.weekOf(OPENING), address(guardian)
        );
        FeastFactory.GenesisParams memory p = _genesisParams();
        p.emissions = address(wrong);
        // The grants read the emissions they were built with, so they are built
        // with this one: the question here is the ledger, and only the ledger.
        p.grants = address(new FeastGenesisGrants(feast, address(wrong), TARGET, partnerList, address(guardian)));
        (bool ok, bytes memory ret) = _genesisCall(p);
        assertFalse(ok, "genesis paid 14.2% to an emissions that reads another ledger");
        assertEq(ret, abi.encodeWithSelector(FeastFactory.EmissionsLedgerMismatch.selector, address(other), address(ledger)));
    }

    /// The control: the fixture's own genuine recipients answer all 18
    /// questions, and each is handed exactly its published share.
    function test_theHonestCeremonyAnswersEveryQuestion() public {
        (bool ok,) = _genesisCall(_genesisParams());
        assertTrue(ok, "the honest ceremony is admitted");
        assertEq(IERC20(feast).balanceOf(address(window)), 600_000_000e18, "60% to the window");
        assertEq(IERC20(feast).balanceOf(address(teamVesting)), 250_000_000e18, "25% to the team");
        assertEq(IERC20(feast).balanceOf(address(emissions)), 142_000_000e18, "14.2% to emissions");
        assertEq(IERC20(feast).balanceOf(address(grants)), 8_000_000e18, "0.8% to the grants");
        assertEq(factory.platformSink(), address(sink), "and the sink is the sink");
    }
}
