// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FiveMin, IERC20} from "../src/FiveMin.sol";
import {IPriceSource} from "../src/PriceSources.sol";
import {MockERC20, MockSource} from "./Mocks.sol";

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
