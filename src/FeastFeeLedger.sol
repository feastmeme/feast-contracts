// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeastGenesis} from "./FeastGenesis.sol";

/// @title The weekly fee ledger
/// @notice Records, for every fee the hook takes, who paid it, whose coin
///         earned it and who referred it — per week, per quote token.
///
/// @dev The first-year emissions and the genesis partners' grants divide real
///      tokens against this record, and neither can correct it afterwards, so
///      it is written on the swap path, by the hook, and by nobody else. There
///      is no Merkle root and no poster: a claim reads this storage directly.
///
///      **Three tracks, each the whole fee.** A trader is credited with the fee
///      they paid, a creator with the fee their coin earned, a referrer with the
///      fee the trade they brought paid — the same number on each track, never
///      a share of it, so a creator's choice of split does not change what the
///      creator track sees, and a referral counts whatever commission the
///      creator set. The referral rule itself (a referrer who is the payer is no
///      referral) is decided once, in the hook, before this is called.
///
///      **Per quote token.** One unit of a four-hundred-dollar share is not one
///      unit of a twenty-dollar one; the emissions contract prices each quote
///      when it settles a week, and never sums raw units across quotes.
///
///      **Packed.** An account's three tracks share one word, and so do a
///      week's three totals for a quote, so a fee costs one write per distinct
///      address plus one for the totals. When two roles are the same address —
///      a creator trading their own coin — they share that one write.
///
///      **Nothing here can revert a swap (I1).** A track is credited only if its
///      total has room; otherwise that fee is not recorded on that track at
///      all, on neither side. Because an account never holds more than its
///      total, the invariant every payout rests on — a total is exactly the sum
///      of its accounts — holds without exception. `uint80` is 1.2 million whole
///      tokens of an 18-decimal quote, in fees, per week, per quote: out of
///      reach for any real stock, and a quote with absurd decimals is one the
///      emissions contract never prices.
contract FeastFeeLedger {
    error NotRecorder();

    event FeesRecorded(
        uint256 indexed week,
        address indexed quote,
        address indexed payer,
        address creator,
        address referrer,
        uint256 amount
    );

    /// @notice One account's fees in one week and quote, or the week's totals —
    ///         as the views return it.
    struct Credit {
        uint80 paid;
        uint80 earned;
        uint80 referred;
    }

    /// @notice The only address that may record: the hook.
    address public immutable recorder;

    /// @dev Storage holds each `Credit` as one packed word — `paid` in bits
    ///      [0, 80), `earned` in [80, 160), `referred` in [160, 240) — and adds
    ///      to it as a word. Measured on the pinned fork, this is 2.4-3.1k gas a
    ///      swap cheaper than copying a struct through memory; the views decode.
    uint256 private constant FIELD = type(uint80).max;
    uint256 private constant EARNED = 80;
    uint256 private constant REFERRED = 160;

    mapping(uint256 week => mapping(address quote => uint256 packed)) internal _totals;
    mapping(uint256 week => mapping(address quote => mapping(address account => uint256 packed))) internal _credits;

    constructor(address recorder_) {
        recorder = recorder_;
    }

    // --- the clock --------------------------------------------------------

    /// @notice The ledger week containing `timestamp`. Weeks turn at Monday
    ///         00:00 UTC.
    function weekOf(uint256 timestamp) public pure returns (uint256) {
        return (timestamp + FeastGenesis.WEEK_ALIGNMENT) / FeastGenesis.WEEK_LENGTH;
    }

    function currentWeek() public view returns (uint256) {
        return weekOf(block.timestamp);
    }

    /// @notice The first second of `week`.
    function weekStart(uint256 week) public pure returns (uint256) {
        return week * FeastGenesis.WEEK_LENGTH - FeastGenesis.WEEK_ALIGNMENT;
    }

    // --- what a payout reads --------------------------------------------------

    function totals(uint256 week, address quote) external view returns (Credit memory) {
        return _decode(_totals[week][quote]);
    }

    function credit(uint256 week, address quote, address account) external view returns (Credit memory) {
        return _decode(_credits[week][quote][account]);
    }

    // --- the write ------------------------------------------------------------

    /// @notice Credit one fee to its payer, its creator and its referrer.
    /// @param creator zero when the fee has no creator track (a burn-address
    ///        creator, whose share is burned rather than owned).
    /// @param referrer zero when the trade was not referred.
    function record(address quote, address payer, address creator, address referrer, uint256 amount) external {
        if (msg.sender != recorder) revert NotRecorder();

        uint256 week = currentWeek();
        uint256 total = _totals[week][quote];
        bool onPaid = payer != address(0) && _fits(total & FIELD, amount);
        bool onEarned = creator != address(0) && _fits((total >> EARNED) & FIELD, amount);
        bool onReferred = referrer != address(0) && _fits(total >> REFERRED, amount);

        // Each flag true only if that field plus `amount` stays inside 80 bits,
        // so no addition below can carry into the next field.
        uint256 paid = onPaid ? amount : 0;
        uint256 earned = onEarned ? amount << EARNED : 0;
        uint256 referred = onReferred ? amount << REFERRED : 0;
        if (paid | earned | referred == 0) return;
        _totals[week][quote] = total + (paid | earned | referred);

        mapping(address => uint256) storage accounts = _credits[week][quote];
        // One write per distinct address. The payer is written first, carrying
        // any other role it also holds; the creator next, unless it was the
        // payer; the referrer last, unless it was either. An account never holds
        // more than its total, so these additions cannot carry either.
        if (onPaid) {
            accounts[payer] += paid | (creator == payer ? earned : 0) | (referrer == payer ? referred : 0);
        }
        bool creatorWritten = onPaid && creator == payer;
        if (onEarned && !creatorWritten) {
            accounts[creator] += earned | (referrer == creator ? referred : 0);
        }
        bool referrerWritten = (onPaid && referrer == payer) || (onEarned && !creatorWritten && referrer == creator);
        if (onReferred && !referrerWritten) {
            accounts[referrer] += referred;
        }

        emit FeesRecorded(
            week, quote, onPaid ? payer : address(0), onEarned ? creator : address(0), onReferred ? referrer : address(0), amount
        );
    }

    function _decode(uint256 packed) private pure returns (Credit memory c) {
        c.paid = uint80(packed);
        c.earned = uint80(packed >> EARNED);
        c.referred = uint80(packed >> REFERRED);
    }

    function _fits(uint256 field, uint256 amount) private pure returns (bool) {
        return amount != 0 && amount <= FIELD && field + amount <= FIELD;
    }
}
