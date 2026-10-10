// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Every number v1.6 adds, in one place.
/// @dev `FeastConstants` holds the per-coin mechanism every pool shares; this
///      file holds what the platform coin's genesis and its first year add. A
///      constant is compiled only into the contracts that read it, so the
///      package-1 values here (the ledger's week, the platform coin, the split,
///      the gate bound) and the package-2 values (added with package 2) never
///      touch each other's bytecode — which the audit brief pins by hash.
///
///      A value that is a deployment decision rather than a design one is a
///      PLACEHOLDER: zero here, refused by the deploy scripts, and passed to the
///      contract that needs it as a constructor argument so tests can use their
///      own fixtures.
library FeastGenesis {
    // --- the chain (deployment facts, read only by the scripts) -----------
    // PancakeSwap Infinity on BNB Smart Chain, as probed at the pinned fork
    // block. Facts, not choices; listed here so the scripts read one file.

    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    address internal constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    address internal constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WRAPPED_NATIVE = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // --- package-1 placeholders (the deploy script refuses while unset) ----

    /// @notice PLACEHOLDER. The one address that may call `genesis`, once.
    address internal constant GENESIS_KEY = 0x08F2C42C9BfCBc8264e22D96a3B1b8eA663A88FF;

    // --- the fee ledger's week (package 1) --------------------------------

    /// @notice Ledger weeks are seven days long.
    uint256 internal constant WEEK_LENGTH = 7 days;
    /// @notice Shifts the week boundary to Monday 00:00 UTC. The Unix epoch
    ///         fell on a Thursday; three more days reaches the next Monday.
    uint256 internal constant WEEK_ALIGNMENT = 3 days;

    // --- the platform coin (package 1) ------------------------------------

    string internal constant PLATFORM_NAME = "Feast";
    string internal constant PLATFORM_SYMBOL = "FEAST";
    /// @notice The whole supply, minted once. To be confirmed by the owner
    ///         before the package-1 freeze.
    uint256 internal constant PLATFORM_SUPPLY = 1_000_000_000e18;
    /// @notice The platform coin's CREATE2 salt, so its address is known from
    ///         the day package 1 is deployed.
    bytes32 internal constant PLATFORM_SALT = keccak256("feast.platform-coin");

    // --- the genesis split (package 1) ------------------------------------
    // Shares of the platform coin's supply, as the owner ruled them on
    // 2026-09-16: 60% into the permanently locked pool, sold through the
    // 24-hour uniform-price window; 25% to the team, vesting linearly over 36
    // months from the window's close (the strategic pocket is inside that 25%,
    // and investors subscribe to it off chain — there is no reserve-allotment
    // or matching-funding parameter here, refused on 2026-09-18); and a 15%
    // one-year bootstrap bucket, 14.2% to emissions and 0.8% to the eight
    // genesis partners (0.1% each).
    //
    //      6_000 + 2_500 + 1_420 + 80 = 10_000
    //
    // Until 2026-09-18 this read 6_500 / 2_000; the bootstrap bucket is
    // unchanged, so only the first two moved and the derivation below lands on
    // the same 1_420 it always has.

    uint16 internal constant BPS = 10_000;
    uint16 internal constant POOL_BPS = 6_000;
    /// @notice How much of `POOL_BPS` the launch window AUCTIONS, the rest
    ///         becoming the pool's ask side once the clearing price is known.
    /// @dev Half and half, because the two jobs are symmetric and neither has a
    ///      reason to dominate: the tranche sets how much of the float the
    ///      auction distributes, and the ask is what a buyer at the open trades
    ///      against. A larger tranche makes the auction more representative and
    ///      the book thinner; a smaller one does the reverse.
    uint16 internal constant WINDOW_TRANCHE_BPS = 5_000;
    uint16 internal constant TEAM_BPS = 2_500;
    uint16 internal constant GRANTS_BPS = 80;
    /// @dev Derived, so the four shares always sum to `BPS`:
    ///      10_000 - 6_000 - 2_500 - 80 = 1_420. The factory hands any
    ///      unit-level rounding remainder to the pool, so the tokens sum to the
    ///      supply exactly as well.
    uint16 internal constant EMISSIONS_BPS = BPS - POOL_BPS - TEAM_BPS - GRANTS_BPS;

    // --- the platform coin's own pool terms (package 1) --------------------
    // The creator is the burn address, so the creator remainder burns too:
    // nine tenths of every FEAST fee burn and one tenth pays whoever brought
    // the trade.

    uint16 internal constant PLATFORM_SELF_BURN_BPS = 2_000;
    uint16 internal constant PLATFORM_REFERRER_BPS = 1_000;

    // --- the roles genesis names (package 1) -------------------------------
    // What each genesis recipient must report from `genesisRole()`.

    bytes32 internal constant ROLE_LAUNCH_WINDOW = keccak256("feast.genesis.launch-window");
    bytes32 internal constant ROLE_TEAM_VESTING = keccak256("feast.genesis.team-vesting");
    bytes32 internal constant ROLE_EMISSIONS = keccak256("feast.genesis.emissions");
    bytes32 internal constant ROLE_GRANTS = keccak256("feast.genesis.grants");
    bytes32 internal constant ROLE_PLATFORM_SINK = keccak256("feast.genesis.platform-sink");

    // --- the gate (package 1) ---------------------------------------------

    /// @notice The longest a pool may be closed to everyone but its opener.
    uint256 internal constant MAX_GATE_DURATION = 14 days;

    // --- emissions (package 2) ---------------------------------------------

    /// @notice The value cap's ratio of a week's fees, and its governed band
    ///         (enforced at the callee, `FeastEmissions.setValueRatioBps`).
    uint16 internal constant DEFAULT_VALUE_RATIO_BPS = 1_500;
    uint16 internal constant MIN_VALUE_RATIO_BPS = 500;
    uint16 internal constant MAX_VALUE_RATIO_BPS = 2_000;
    /// @notice Most of a week's new emission that may be redirected to a bridge
    ///         escrow (owner ruling Q26).
    uint16 internal constant MAX_REDIRECT_BPS = 5_000;
    /// @notice 52 weeks from the factory's opening week (owner ruling Q8).
    uint256 internal constant EMISSION_WEEKS = 52;
    /// @notice The token cap falls linearly: week n may emit
    ///         `budget × (53 − n) / 1378`, and 1 + 2 + … + 52 = 1378.
    uint256 internal constant CURVE_DENOMINATOR = 1_378;
    /// @notice Track weights (referrer / trader / creator): weeks 1–8, then 9+.
    uint256 internal constant EARLY_WEEKS = 8;
    uint16 internal constant EARLY_REFERRER_BPS = 4_000;
    uint16 internal constant EARLY_TRADER_BPS = 4_500;
    uint16 internal constant EARLY_CREATOR_BPS = 1_500;
    uint16 internal constant LATE_REFERRER_BPS = 2_000;
    uint16 internal constant LATE_TRADER_BPS = 6_500;
    uint16 internal constant LATE_CREATOR_BPS = 1_500;
    /// @notice A listed quote that cannot be priced blocks its week's settlement
    ///         for this long after the week closes, then counts as zero (Q11).
    uint256 internal constant PRICING_GRACE = 3 days;
    /// @notice A settled week stays claimable this long after claims open.
    uint256 internal constant CLAIM_GRACE = 12 weeks;

    // --- genesis grants (package 2) ------------------------------------------

    uint256 internal constant PARTNERS = 8;
    uint16 internal constant GRANT_BPS_EACH = 10;
    /// @notice Partners' referred fees count in emission weeks 1–26 (Q22).
    uint256 internal constant GRANT_WEEKS = 26;

    // --- the launch window (package 2) ---------------------------------------

    uint256 internal constant WINDOW_DURATION = 24 hours;
    /// @notice Commits may be withdrawn until this long before the window ends.
    uint256 internal constant WINDOW_LOCK = 1 hours;
    /// @notice The hour after the window closes in which only the window may
    ///         trade the platform pool; genesis sets
    ///         `openAt = window end + SETTLE_GRACE` (Q12).
    /// @dev Until v1.6.24 this was also the ONLY hour in which the window could
    ///      settle, and a settle that did not land in it stranded the window's
    ///      60% of supply for ever (AstraSec M-2). It is now only the pool's
    ///      gate: `settle` is callable from the close until it succeeds, and a
    ///      settle after `openAt` opens the pool to the public in the same
    ///      transaction.
    uint256 internal constant SETTLE_GRACE = 1 hours;
    /// @notice The smallest pot that counts as participation. A pot below it —
    ///         or one too small to price at all — buys nothing: the window
    ///         opens the pool as if nobody had committed, and every commit is
    ///         refunded in full (v1.6.24, AstraSec M-2).
    /// @dev A floor on dust, not a reserve price: a pot of exactly this clears
    ///      the whole tranche at this price. About 6e10 times the pot below
    ///      which the clearing price cannot be represented, so in either currency
    ///      ordering no pot that meets it is unrepresentable. **Owner to confirm
    ///      at the genesis-parameter review** (coordinator ruling, 2026-10-01);
    ///      changing it is this one constant.
    uint256 internal constant MIN_POT = 1 ether;
    /// @notice How long after the window closes its auction may still clear.
    ///         From `endsAt + ABANDON_AFTER` — extended by every second the
    ///         guardian has held the brake — `settle` opens the pool as if
    ///         nobody had committed and every commit is refundable.
    /// @dev The safety valve the grace hour used to be, without its deadline
    ///      for the COIN: the coin can always reach the pool, the auction can
    ///      expire. **Owner to confirm at the genesis-parameter review**
    ///      (coordinator ruling, 2026-10-01); changing it is this one constant.
    uint256 internal constant ABANDON_AFTER = 7 days;

    // --- team vesting (package 2) --------------------------------------------

    /// @notice 36 months of 30.4375 days, linear, no cliff, from the window's
    ///         close (owner, 2026-09-11).
    uint64 internal constant TEAM_VESTING_DURATION = 94_672_800;

    // --- the timelock (package 2) --------------------------------------------

    uint256 internal constant TIMELOCK_DELAY = 3 days;

    // --- the platform sink (package 2) ---------------------------------------

    /// @notice The descending price halves this often (Q16).
    uint256 internal constant SINK_HALF_LIFE = 1 hours;
    /// @notice Where a newly opened lot's price starts: far above any real
    ///         value, so it can only descend into the market.
    uint256 internal constant SINK_START_PRICE_Q128 = 1 << 192;
    /// @notice Once an asset has sold, its price never falls below the last
    ///         sale's price halved this many times — at the moment of that sale.
    uint256 internal constant SINK_FLOOR_HALVINGS = 6;
    /// @notice The floor has a clock of its own: it halves this often since the
    ///         last sale, so a lot the market has left behind comes back within
    ///         reach in days rather than never (v1.6.2, H2).
    uint256 internal constant SINK_FLOOR_HALF_LIFE = 24 hours;
    /// @notice A lot that holds at least this multiple of what it held when its
    ///         descent began is a different lot: the descent priced the smaller
    ///         one and says nothing about this one (v1.6.2).
    uint256 internal constant SINK_REOPEN_MULTIPLE = 2;

    // --- package-2 placeholders (the scripts refuse while any is unset) -------

    /// @notice PLACEHOLDER. Receives the team's 25% through its vesting wallet.
    address internal constant TEAM_BENEFICIARY = 0xE64a490E0FaeAC7240172C524136Ed6d523D79cF;
    /// @notice PLACEHOLDER. The timelock's only proposer (Q27).
    address internal constant TEAM_MULTISIG = 0xE64a490E0FaeAC7240172C524136Ed6d523D79cF;
    /// @notice PLACEHOLDER. Referred fees, in WBNB wei, that unlock a whole grant.
    uint256 internal constant TARGET_NATIVE = 100e18; // 100 WBNB, owner ruling 2026-10-07 (#4 of the genesis table)
    /// @notice PLACEHOLDER. The timestamp the factory opens; emission week 1 is
    ///         its ledger week.
    uint256 internal constant FACTORY_OPENING = 1791763200; // 2026-10-12T00:00:00Z, the public opening Monday (owner ruling 2026-10-08 20:5x): emission week 1 = 2026-10-12..18
    /// @notice PLACEHOLDER. The launch window's first second; the window ends
    ///         24 hours later, which must be a Monday 00:00 UTC.
    uint256 internal constant WINDOW_START = 0;
    /// @notice PLACEHOLDER. The platform coin's opening tick (an owner number, Q21).
    int24 internal constant PLATFORM_OPENING_TICK = -161200; // owner ruling 2026-10-07 23:5x: floor FDV 100 BNB = 1e-7 BNB/FEAST; FEAST sorts before WBNB (currency0), so negative
    bool internal constant PLATFORM_OPENING_TICK_SET = true;
    /// @notice PLACEHOLDER. The platform coin's metadata digest.
    bytes32 internal constant PLATFORM_METADATA_HASH = 0xbecf382745e4d7a4361bdbbece92746cbe39cc053157b6e020730bbb6f709aa2;

    /// @notice PLACEHOLDER. The package-1 factory, once deployed; everything
    ///         else package 2 needs from package 1 is read from it.
    address internal constant PACKAGE1_FACTORY = 0x1003b54659F5e31A7391fEBE824A137e8CDa90da; // predicted: CREATE(GENESIS_KEY, nonce 9) with package 1 starting at nonce 1 (owner ruling 2026-10-08 20:5x: pre-fill, verify on-chain before package 2)
    /// @notice PLACEHOLDER. Package 2's core, once deployed (read by the genesis
    ///         script).
    address internal constant PACKAGE2_EMISSIONS = 0x7981B9a363F724410A2a802e2018B8aD0f76293c; // predicted: CREATE nonce 12 (verify on-chain before genesis)
    address internal constant PACKAGE2_GRANTS = 0xcF72d46C6A3b66F559Ab0D65C98f9F0C1e3F6DcD; // predicted: CREATE nonce 13
    address internal constant PACKAGE2_SINK = 0x59BA4f39Ce8a405d1C08979680f051c17dC8BBFB; // predicted: CREATE nonce 14
    /// @notice Whether the priced-quote routes below have been confirmed by the
    ///         owner, by symbol AND address (README step 1). Ruled 2026-10-08.
    bool internal constant PRICED_ROUTES_CONFIRMED = true;

    /// @notice The priced quotes and their v3 routes to wrapped native. Confirmed by the
    ///         owner by symbol AND address on 2026-10-08 (README step 1; ten quotes,
    ///         ruled from pool depth and 24h volume; survey in the genesis vault).
    function pricedRoutes() internal pure returns (address[] memory quotes, address[][] memory pools) {
        quotes = new address[](10);
        pools = new address[][](10);

        // [0] NVDAB — NVIDIA Corp
        quotes[0] = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
        pools[0] = new address[](2);
        pools[0][0] = 0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C; // NVDAB/USDT fee 2500
        pools[0][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [1] SPCXB — SpaceX
        quotes[1] = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
        pools[1] = new address[](1);
        pools[1][0] = 0x66faaD27cf481f82d0089ec8156B3AA3636010C7; // SPCXB/WBNB fee 2500

        // [2] TSLAB — Tesla, Inc.
        quotes[2] = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
        pools[2] = new address[](2);
        pools[2][0] = 0xB0f5E5400E8F0F7C242F2b7740C004f020579c41; // TSLAB/USDT fee 2500
        pools[2][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [3] QQQB — Invesco QQQ
        quotes[3] = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
        pools[3] = new address[](1);
        pools[3][0] = 0x47BC06722295AC316A569EEF87aC32FAA455F441; // QQQB/WBNB fee 500

        // [4] GOOGLB — Alphabet
        quotes[4] = 0x3F53De71c126BdaBAe20f9cD64848d317f6C3238;
        pools[4] = new address[](2);
        pools[4][0] = 0x89001D846f7CA36EE089F73eEFC25657E1798144; // GOOGLB/USDT fee 2500
        pools[4][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [5] BABAB — Alibaba
        quotes[5] = 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec;
        pools[5] = new address[](2);
        pools[5][0] = 0xfD95CB1391999006Eb91797a7c62acFe88b20292; // BABAB/USDT fee 2500
        pools[5][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [6] SKHYB — SK Hynix
        quotes[6] = 0xCA750eF65f295BBECd685Abf54e82CAf297BDB61;
        pools[6] = new address[](2);
        pools[6][0] = 0xD7d30F434b12F7Ed9b0Ae11fF1C754745a10aD52; // SKHYB/USDT fee 2500
        pools[6][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [7] AAPLB — Apple
        quotes[7] = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
        pools[7] = new address[](2);
        pools[7][0] = 0xe9b9998B2EC5430D2246c7f1F8D9f298c97D7365; // AAPLB/USDT fee 2500
        pools[7][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [8] CRCLB — Circle Internet Group Inc.
        quotes[8] = 0x80f3D493EBCe97e343c53D29a137942416B4ffC0;
        pools[8] = new address[](2);
        pools[8][0] = 0x29967c54c5Bf12E8158c8894376064b30ebaB297; // CRCLB/USDT fee 2500
        pools[8][1] = 0x172fcD41E0913e95784454622d1c3724f546f849; // USDT/WBNB fee 100

        // [9] BNCB — CEA Industries
        quotes[9] = 0x4902C5ebc598265Ed2212b559B042De8a5Eeec3f;
        pools[9] = new address[](1);
        pools[9][0] = 0x320e8096e5e7a46E43446141A5B15d801FC596f5; // BNCB/WBNB fee 2500 (ring 300 -> 601 requested before package 2)
    }

    /// @notice The buy-back button's tip floor for each listed stock quote, in raw
    ///         units of that stock: the amount worth 0.0005 BNB
    ///         (`FeastConstants.TIP_FLOOR_NATIVE`) read from the quote's own route
    ///         pools at block 126426061 (2026-10-08). Wrapped native is not a row
    ///         here; the deploy script adds it. Re-read on deploy day and refresh
    ///         any row whose quote moved more than 20%.
    function tipFloors() internal pure returns (address[] memory quotes, uint256[] memory floors) {
        quotes = new address[](10);
        floors = new uint256[](10);
        quotes[0] = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436; // NVDAB
        floors[0] = 1627093838451565; // 0.307296 WBNB per NVDAB
        quotes[1] = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1; // SPCXB
        floors[1] = 2294030623622614; // 0.217957 WBNB per SPCXB
        quotes[2] = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f; // TSLAB
        floors[2] = 1023592415497530; // 0.488476 WBNB per TSLAB
        quotes[3] = 0x205812CdBed920aFf76C6580abD681a46D11efc7; // QQQB
        floors[3] = 509700171219757; // 0.980969 WBNB per QQQB
        quotes[4] = 0x3F53De71c126BdaBAe20f9cD64848d317f6C3238; // GOOGLB
        floors[4] = 1100906781278604; // 0.454171 WBNB per GOOGLB
        quotes[5] = 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec; // BABAB
        floors[5] = 3593994156252248; // 0.139121 WBNB per BABAB
        quotes[6] = 0xCA750eF65f295BBECd685Abf54e82CAf297BDB61; // SKHYB
        floors[6] = 2174504847384277; // 0.229937 WBNB per SKHYB
        quotes[7] = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A; // AAPLB
        floors[7] = 1142032005751318; // 0.437816 WBNB per AAPLB
        quotes[8] = 0x80f3D493EBCe97e343c53D29a137942416B4ffC0; // CRCLB
        floors[8] = 4778291342341539; // 0.104640 WBNB per CRCLB
        quotes[9] = 0x4902C5ebc598265Ed2212b559B042De8a5Eeec3f; // BNCB
        floors[9] = 69632209830079976; // 0.007181 WBNB per BNCB
    }

    /// @notice PLACEHOLDER. The eight genesis partners, fixed at genesis.
    function partners() internal pure returns (address[8] memory) {
        return [address(0), address(0), address(0), address(0), address(0), address(0), address(0), address(0)];
    }
}
