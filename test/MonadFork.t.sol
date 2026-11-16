// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IPyth} from "hl-price-guard/src/PythRef.sol";
import {FiveMin, IERC20} from "../src/FiveMin.sol";
import {IPriceSource, PythPushSource} from "../src/PriceSources.sol";
import {MockERC20} from "./Mocks.sol";

/// One real round on Monad mainnet: BTC, the round starting 2026-11-15 04:05:00 UTC (1794715500).
/// Pyth's sponsored push feed updated BTC/USD at publishTime 1794715528 (block 122356773), the
/// first update after the start, and at 1794715802 (block 122357676), the first after the end.
/// Found with eth_getLogs for PriceFeedUpdate on 0x2880…7B43. Needs an RPC that serves state at
/// those blocks (`monad` in foundry.toml).
contract MonadForkTest is Test {
    IPyth constant PYTH = IPyth(0x2880aB155794e7179c9eE2e38200202908C17B43);
    bytes32 constant BTC = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint64 constant T = 1794715500;
    uint256 constant BET_BLOCK = 122356650; // timestamp 1794715492, 8 s before the start
    uint256 constant OPEN_BLOCK = 122356773;
    uint256 constant CLOSE_BLOCK = 122357676;
    uint256 constant ASSET = 1;

    FiveMin fm;
    MockERC20 usd;
    PythPushSource src;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.createSelectFork("monad", BET_BLOCK);
        usd = new MockERC20();
        src = new PythPushSource(PYTH, 50);
        fm = new FiveMin(treasury);
        fm.list(
            ASSET,
            FiveMin.Listing({
                source: IPriceSource(address(src)),
                feed: BTC,
                token: IERC20(address(usd)),
                maxDelay: 90,
                feeBps: 200,
                minStake: 1e6,
                paused: false
            })
        );
        vm.makePersistent(address(fm), address(usd), address(src));
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 3; i++) {
            usd.mint(who[i], 1_000e6);
            vm.prank(who[i]);
            usd.approve(address(fm), type(uint256).max);
        }
    }

    function test_realRound_btc_downWins() public {
        assertLt(block.timestamp, T, "bets go in before the start");
        vm.prank(alice);
        fm.bet(ASSET, T, true, 100e6);
        vm.prank(bob);
        fm.bet(ASSET, T, false, 60e6);
        vm.prank(carol);
        fm.bet(ASSET, T, false, 40e6);
        console2.log(
            "bets at block %s, %s s before the start: alice Up 100, bob Down 60, carol Down 40",
            block.number,
            T - block.timestamp
        );

        // A poke before any update after the start records nothing.
        fm.poke(ASSET, T);
        (,,,, uint64 openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openAt, 0);

        vm.rollFork(OPEN_BLOCK);
        fm.poke(ASSET, T);
        (,, uint256 openPx,, uint64 at,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(at, 1794715528, "the first update after the start");
        assertEq(openPx, 64725.57339582e18);
        console2.log(
            "open  recorded at block %s: BTC %s, published %s s after the start", block.number, openPx / 1e18, at - T
        );

        vm.rollFork(CLOSE_BLOCK);
        fm.poke(ASSET, T);
        (,,, uint256 closePx,, uint64 closeAt,) = fm.rounds(fm.key(ASSET, T));
        assertEq(closeAt, 1794715802, "the first update after the end");
        assertEq(closePx, 64634.05983568e18);
        console2.log(
            "close recorded at block %s: BTC %s, published %s s after the end",
            block.number,
            closePx / 1e18,
            closeAt - T - 300
        );

        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Down));
        vm.prank(bob);
        assertEq(fm.claim(ASSET, T), 60e6 + 58.8e6);
        vm.prank(carol);
        assertEq(fm.claim(ASSET, T), 40e6 + 39.2e6);
        assertEq(fm.payout(ASSET, T, alice), 0);
        assertEq(fm.collectFee(ASSET, T), 2e6);
        console2.log("Down won: bob claims 118.8, carol 79.2, alice 0, fee 2 (2% of the losing side)");
        assertEq(usd.balanceOf(address(fm)), 0);
    }
}
