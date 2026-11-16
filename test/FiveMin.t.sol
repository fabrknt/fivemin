// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FiveMin, IERC20} from "../src/FiveMin.sol";
import {IPriceSource} from "../src/PriceSources.sol";
import {FeeOnPayoutERC20, FeeOnTransferERC20, MockERC20, MockSource} from "./Mocks.sol";

contract FiveMinTest is Test {
    FiveMin fm;
    MockERC20 usd;
    MockSource src;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    uint256 constant ASSET = 1;
    uint64 constant T = 1_800_000_000; // a multiple of 300
    uint64 constant MAX_DELAY = 90;

    function setUp() public {
        vm.warp(T - 60);
        usd = new MockERC20();
        src = new MockSource();
        fm = new FiveMin(treasury);
        fm.list(
            ASSET,
            FiveMin.Listing({
                source: IPriceSource(address(src)),
                feed: bytes32(0),
                token: IERC20(address(usd)),
                maxDelay: MAX_DELAY,
                feeBps: 200,
                minStake: 1e6,
                paused: false
            })
        );
        for (uint256 i; i < 3; i++) {
            address a = [alice, bob, carol][i];
            usd.mint(a, 1_000e6);
            vm.prank(a);
            usd.approve(address(fm), type(uint256).max);
        }
    }

    function _bet(address who, bool up, uint256 amount) internal {
        vm.prank(who);
        fm.bet(ASSET, T, up, amount);
    }

    function _record(uint256 openPx, uint64 openAt, uint256 closePx, uint64 closeAt) internal {
        vm.warp(openAt);
        src.set(openPx, openAt);
        fm.poke(ASSET, T);
        vm.warp(closeAt);
        src.set(closePx, closeAt);
        fm.poke(ASSET, T);
    }

    function test_fullRound_downWins_feeFromLosersOnly() public {
        _bet(alice, true, 100e6);
        _bet(bob, false, 60e6);
        _bet(carol, false, 40e6);
        _record(100e18, T + 5, 99e18, T + 300 + 5);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Down));
        // pot = 100 - 2% = 98, split 60:40
        assertEq(fm.payout(ASSET, T, bob), 60e6 + 58.8e6);
        assertEq(fm.payout(ASSET, T, carol), 40e6 + 39.2e6);
        assertEq(fm.payout(ASSET, T, alice), 0);
        vm.prank(bob);
        fm.claim(ASSET, T);
        vm.prank(carol);
        fm.claim(ASSET, T);
        assertEq(fm.collectFee(ASSET, T), 2e6);
        assertEq(usd.balanceOf(treasury), 2e6);
        assertEq(usd.balanceOf(address(fm)), 0);
        assertEq(fm.collectFee(ASSET, T), 0, "fee once");
    }

    function test_readingBeforeT_orAfterWindow_isNotRecorded() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        // published before T: not the price at T
        vm.warp(T + 1);
        src.set(100e18, T - 1);
        fm.poke(ASSET, T);
        (,,,, uint64 openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openAt, 0);
        // published after T + maxDelay: too late
        vm.warp(T + MAX_DELAY + 2);
        src.set(100e18, T + MAX_DELAY + 1);
        fm.poke(ASSET, T);
        (,,,, openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openAt, 0);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void), "missed checkpoint voids");
    }

    function test_recordedPriceNeverChanges() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T + 5);
        src.set(100e18, T + 5);
        fm.poke(ASSET, T);
        vm.warp(T + 30);
        src.set(150e18, T + 30); // a later, more favourable print inside the window
        fm.poke(ASSET, T);
        (,, uint256 openPx,, uint64 openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openPx, 100e18);
        assertEq(openAt, T + 5);
    }

    /// The same for the close: deleting `r.closeAt == 0 &&` in poke failed no test before this one,
    /// and would let whoever pokes last inside the window pick the closing price.
    function test_recordedCloseNeverChanges() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T + 5);
        src.set(100e18, T + 5);
        fm.poke(ASSET, T);
        vm.warp(T + 302);
        src.set(90e18, T + 302);
        fm.poke(ASSET, T);
        vm.warp(T + 330);
        src.set(150e18, T + 330); // a later print inside the window that would flip the outcome to Up
        fm.poke(ASSET, T);
        (,,, uint256 closePx,, uint64 closeAt,) = fm.rounds(fm.key(ASSET, T));
        assertEq(closePx, 90e18);
        assertEq(closeAt, T + 302);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Down));
    }

    function test_void_oneSided_refundsAll() public {
        _bet(alice, true, 10e6);
        _bet(bob, true, 5e6);
        _record(100e18, T + 5, 120e18, T + 305);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
        assertEq(fm.payout(ASSET, T, alice), 10e6);
        assertEq(fm.payout(ASSET, T, bob), 5e6);
    }

    function test_void_equalPrice_refundsAll() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 7e6);
        _record(100e18, T + 5, 100e18, T + 305);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
        vm.prank(bob);
        assertEq(fm.claim(ASSET, T), 7e6);
        vm.prank(bob);
        vm.expectRevert(FiveMin.AlreadyClaimed.selector);
        fm.claim(ASSET, T);
    }

    function test_void_missedClose() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T + 5);
        src.set(100e18, T + 5);
        fm.poke(ASSET, T);
        vm.warp(T + 300 + MAX_DELAY);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Pending), "still inside the window");
        vm.warp(T + 300 + MAX_DELAY + 1);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
    }

    function test_betsRefused_atStart_andTooEarly() public {
        vm.warp(T);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.BetsClosed.selector, T));
        fm.bet(ASSET, T, true, 1e6);

        vm.warp(T - 3601);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.BetsNotOpen.selector, T));
        fm.bet(ASSET, T, true, 1e6);

        vm.warp(T - 3600);
        _bet(alice, true, 1e6); // exactly one hour before is allowed

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.BadStartTime.selector, T + 1));
        fm.bet(ASSET, T + 1, true, 1e6);
    }

    function test_listingIsFixed_andPauseStopsOnlyNewBets() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.AlreadyListed.selector, ASSET));
        fm.list(
            ASSET,
            FiveMin.Listing({
                source: IPriceSource(address(src)),
                feed: bytes32(0),
                token: IERC20(address(usd)),
                maxDelay: 1,
                feeBps: 0,
                minStake: 1,
                paused: false
            })
        );
        fm.setPaused(ASSET, true);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.IsPaused.selector, ASSET));
        fm.bet(ASSET, T, true, 1e6);
        _record(100e18, T + 5, 101e18, T + 305); // the paused asset's round still settles
        assertEq(fm.payout(ASSET, T, alice), 10e6 + 9.8e6);
    }

    /// Review r1 blocker: after a checkpoint's deadline a poke records nothing, even with a reading
    /// stamped inside the window, so a round that went Void stays Void.
    function test_latePoke_recordsNothing_voidStaysVoid() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T + 5);
        src.set(100e18, T + 5);
        fm.poke(ASSET, T);
        src.set(150e18, T + 300 + 5); // a close stamped inside the window, never poked in time
        vm.warp(T + 300 + MAX_DELAY + 1);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
        fm.poke(ASSET, T);
        (,,,,, uint64 closeAt,) = fm.rounds(fm.key(ASSET, T));
        assertEq(closeAt, 0);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
    }

    /// Review r1: a reading stamped ahead of the block is not the price at that block.
    function test_readingAheadOfTheBlock_isNotRecorded() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T);
        src.set(100e18, T + 30);
        fm.poke(ASSET, T);
        (,,,, uint64 openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openAt, 0);
    }

    function test_listing_capsTheWindow_andRefusesTokensWithoutCode() public {
        FiveMin.Listing memory l = FiveMin.Listing({
            source: IPriceSource(address(src)),
            feed: bytes32(0),
            token: IERC20(address(usd)),
            maxDelay: 121, // MockSource allows 120
            feeBps: 0,
            minStake: 1,
            paused: false
        });
        vm.expectRevert(FiveMin.BadListing.selector);
        fm.list(2, l);
        l.maxDelay = 120;
        l.token = IERC20(makeAddr("no code"));
        vm.expectRevert(FiveMin.BadListing.selector);
        fm.list(2, l);
    }

    /// Review r1: a token that keeps part of each transfer is refused at the first bet.
    function test_feeOnTransferToken_refused() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        fm.list(
            3,
            FiveMin.Listing({
                source: IPriceSource(address(src)),
                feed: bytes32(0),
                token: IERC20(address(fot)),
                maxDelay: MAX_DELAY,
                feeBps: 0,
                minStake: 1,
                paused: false
            })
        );
        fot.mint(alice, 100);
        vm.startPrank(alice);
        fot.approve(address(fm), 100);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.NotExact.selector, 100, 90));
        fm.bet(3, T, true, 100);
        vm.stopPrank();
    }

    function test_zeroAddresses_andTwoStepOwner() public {
        vm.expectRevert(FiveMin.ZeroAddress.selector);
        new FiveMin(address(0));
        vm.expectRevert(FiveMin.ZeroAddress.selector);
        fm.setTreasury(address(0));
        fm.transferOwnership(alice);
        assertEq(fm.owner(), address(this), "not until accepted");
        vm.prank(bob);
        vm.expectRevert(FiveMin.NotPendingOwner.selector);
        fm.acceptOwnership();
        vm.prank(alice);
        fm.acceptOwnership();
        assertEq(fm.owner(), alice);
    }

    // ---- added after unproven's first run (unproven.toml): each closes an unproven row ----

    function _listing(uint64 maxDelay, uint16 feeBps, uint128 minStake) internal view returns (FiveMin.Listing memory) {
        return FiveMin.Listing({
            source: IPriceSource(address(src)),
            feed: bytes32(0),
            token: IERC20(address(usd)),
            maxDelay: maxDelay,
            feeBps: feeBps,
            minStake: minStake,
            paused: false
        });
    }

    function test_onlyTheOwnerAdministers() public {
        vm.startPrank(alice);
        vm.expectRevert(FiveMin.NotOwner.selector);
        fm.list(2, _listing(MAX_DELAY, 0, 1));
        vm.expectRevert(FiveMin.NotOwner.selector);
        fm.setPaused(ASSET, true);
        vm.expectRevert(FiveMin.NotOwner.selector);
        fm.setTreasury(alice);
        vm.expectRevert(FiveMin.NotOwner.selector);
        fm.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_listing_refusesBadSettings() public {
        vm.expectRevert(FiveMin.BadListing.selector);
        fm.list(2, _listing(0, 0, 1)); // a zero window: no checkpoint could ever be recorded
        vm.expectRevert(FiveMin.BadListing.selector);
        fm.list(2, _listing(MAX_DELAY, 501, 1)); // a fee above 5%
        vm.expectRevert(FiveMin.BadListing.selector);
        fm.list(2, _listing(MAX_DELAY, 0, 0)); // no minimum stake
        fm.list(2, _listing(MAX_DELAY, 500, 1)); // the limits themselves are allowed
    }

    function test_bet_belowMinStake_refused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.StakeTooSmall.selector, 1e6 - 1, 1e6));
        fm.bet(ASSET, T, true, 1e6 - 1);
    }

    /// Without the finality check a fee would be taken from a side that may still win.
    function test_collectFee_refusedWhilePending() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.expectRevert(FiveMin.NotFinal.selector);
        fm.collectFee(ASSET, T);
    }

    /// A void round pays every stake back, so it has no fee.
    function test_collectFee_noFeeOnAVoidRound() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T + MAX_DELAY + 1); // the start was never recorded
        assertEq(fm.collectFee(ASSET, T), 0);
        assertEq(usd.balanceOf(treasury), 0);
        vm.prank(alice);
        fm.claim(ASSET, T);
        vm.prank(bob);
        fm.claim(ASSET, T);
        assertEq(usd.balanceOf(address(fm)), 0);
    }

    /// A round with only Down stakes is void whichever way the price goes: if Up won, nobody
    /// could claim and the stakes would stay in the contract.
    function test_void_downOnly_evenIfUpWins() public {
        _bet(alice, false, 10e6);
        _bet(bob, false, 5e6);
        _record(100e18, T + 5, 120e18, T + 305);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
        assertEq(fm.payout(ASSET, T, alice), 10e6);
    }

    function test_claim_loserGetsNothing_andPayoutIsZeroAfterClaim() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        _record(100e18, T + 5, 101e18, T + 305);
        vm.prank(bob);
        vm.expectRevert(FiveMin.NothingToClaim.selector);
        fm.claim(ASSET, T);
        vm.prank(alice);
        fm.claim(ASSET, T);
        assertEq(fm.payout(ASSET, T, alice), 0, "a claimed payout reads 0");
    }

    /// A token that keeps part of each outgoing transfer cannot pay a winner in full.
    function test_feeOnPayoutToken_refusedAtClaim() public {
        FeeOnPayoutERC20 fop = new FeeOnPayoutERC20();
        FiveMin.Listing memory l = _listing(MAX_DELAY, 0, 1);
        l.token = IERC20(address(fop));
        fm.list(4, l);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; i++) {
            fop.mint(who[i], 100);
            vm.prank(who[i]);
            fop.approve(address(fm), 100);
        }
        vm.prank(alice);
        fm.bet(4, T, true, 100);
        vm.prank(bob);
        fm.bet(4, T, false, 100);
        vm.warp(T + 5);
        src.set(100e18, T + 5);
        fm.poke(4, T);
        vm.warp(T + 305);
        src.set(101e18, T + 305);
        fm.poke(4, T);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiveMin.NotExact.selector, 200, 180));
        fm.claim(4, T);
    }

    /// Winners never get less than their stake, and claims plus the fee never exceed the stakes.
    function testFuzz_payoutsNeverExceedStakes(uint96 a, uint96 b, uint96 c, bool cUp, bool upWins) public {
        uint256 sa = bound(a, 1e6, 1_000e6);
        uint256 sb = bound(b, 1e6, 1_000e6);
        uint256 sc = bound(c, 1e6, 1_000e6);
        for (uint256 i; i < 3; i++) {
            usd.mint([alice, bob, carol][i], 1_000e6);
        }
        _bet(alice, true, sa);
        _bet(bob, false, sb);
        _bet(carol, cUp, sc);
        _record(100e18, T + 5, upWins ? 101e18 : 99e18, T + 305);
        uint256 paid;
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory st = [sa, sb, sc];
        bool[3] memory up = [true, false, cUp];
        for (uint256 i; i < 3; i++) {
            uint256 p = fm.payout(ASSET, T, who[i]);
            if (up[i] == upWins) assertGe(p, st[i], "a winner gets at least their stake");
            else assertEq(p, 0, "a loser gets nothing");
            if (p != 0) {
                vm.prank(who[i]);
                fm.claim(ASSET, T);
                paid += p;
            }
        }
        paid += fm.collectFee(ASSET, T);
        assertLe(paid, sa + sb + sc);
        assertEq(usd.balanceOf(address(fm)), sa + sb + sc - paid, "only dust stays");
        assertLe(sa + sb + sc - paid, 3, "dust is at most a unit per winner");
    }
}
