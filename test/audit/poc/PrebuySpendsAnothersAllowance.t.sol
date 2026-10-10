// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeastConstants} from "../../../src/FeastConstants.sol";
import {FeastFactory} from "../../../src/FeastFactory.sol";
import {FeastVesting} from "../../../src/FeastVesting.sol";
import {PoolKey} from "../../../src/venue/PoolKey.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {UnitFixture} from "../../utils/UnitFixture.sol";

/// PoC for the v1.6.11 round's HIGH `unauthorized-creator-prebuy`, reported by the
/// economic-promise unit `P6b` (codex) at `src/FeastFactory.sol:562`.
///
/// The pre-buy pulls the quote from the address named in the parameters, not from the caller:
///
///     // src/FeastFactory.sol:562
///     IERC20(p.quote).safeTransferFrom(p.creator, address(this), p.prebuyQuoteIn);
///
/// `create` is permissionless and `p.creator` is a free parameter — there is no
/// `msg.sender == p.creator` anywhere on the path. So the approval a creator must give the
/// factory in order to pre-buy their OWN coin is spendable by anybody, on a coin of the
/// stranger's choosing, with a vesting duration of the stranger's choosing.
///
/// The victim is not robbed outright: the coins are allocated to them. They are robbed of the
/// CHOICE — their quote buys an asset they never picked, and the vesting duration is set by
/// whoever pressed the button, so a stranger can lock a creator's capital in a worthless coin
/// for a hundred years. An approval to a contract is a promise about what that contract will
/// spend it on; this one makes no such promise.
///
/// `docs/interface.md` and the P6 promise describe the pre-buy as *the creator's* stake, bought
/// by the creator at creation. Nothing warns an approver that the factory will move their funds
/// at anyone's request.
contract PrebuySpendsAnothersAllowancePoC is UnitFixture {
    address internal victim = address(0x71C7104);
    address internal stranger = address(0x5174A9E);

    function _params(address quote, address whoPays, uint256 quoteIn, uint64 vestingDuration, bytes32 salt)
        internal
        pure
        returns (FeastFactory.CreateParams memory)
    {
        return FeastFactory.CreateParams({
            name: "Coin",
            symbol: "COIN",
            supply: 1_000_000_000e18,
            quote: quote,
            creator: whoPays,
            selfBurnBps: 2_000,
            referrerBps: 1_000,
            prebuyQuoteIn: quoteIn,
            minCoinsOut: 0,
            vestingDuration: vestingDuration,
            sqrtPriceX96: 79_228_162_514_264_337_593_543_950_336,
            startTick: 0,
            liquidity: uint128(1_000_000_000e18 * 999 / 1_000),
            salt: salt,
            metadataHash: bytes32(0)
        });
    }

    /// The control: a creator pre-buying their own coin works, so the mechanism is not broken
    /// in general and what follows is about WHO may press it.
    function test_aCreatorCanPrebuyTheirOwnCoin() public {
        wbnb.mint(victim, 10e18);
        vm.prank(victim);
        IERC20(address(wbnb)).approve(address(factory), 10e18);

        vm.prank(victim);
        // v1.6.24 I-5: a week, the least a pre-buy may vest.
        factory.create(_params(address(wbnb), victim, 10e18, 7 days, bytes32(uint256(1))));
        assertEq(wbnb.balanceOf(victim), 0, "the creator spent their own approval, as they meant to");
    }

    /// A stranger spends it instead, on a coin the victim never chose, locked for a century.
    function test_aStrangerCannotSpendACreatorsApproval() public {
        wbnb.mint(victim, 10e18);
        vm.prank(victim);
        IERC20(address(wbnb)).approve(address(factory), 10e18);

        // The victim has not called anything. The stranger does, naming the victim as creator.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(FeastFactory.PrebuyNeedsTheCreator.selector, victim, stranger)
        );
        factory.create(_params(address(wbnb), victim, 10e18, 100 * 365 days, bytes32(uint256(2))));

        assertEq(
            wbnb.balanceOf(victim),
            10e18,
            "the victim's approval is still theirs to spend"
        );
    }

    /// The gate is on the PRE-BUY and not on creation: making a coin for
    /// somebody else, with no pre-buy, spends nothing of theirs and stays
    /// permissionless. Kills: a fix that gated `create` itself.
    function test_creatingACoinForSomebodyElseWithNoPrebuyStillWorks() public {
        vm.prank(stranger);
        factory.create(_params(address(wbnb), victim, 0, 0, bytes32(uint256(3))));
        address[] memory coins = factory.listCoins();
        assertEq(factory.getCoin(coins[coins.length - 1]).creator, victim, "created for the named creator");
    }
}
