// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {HLPrecompiles} from "hl-price-guard/src/HLPrecompiles.sol";
import {FiveMin, IERC20} from "../src/FiveMin.sol";
import {Hip3Source, IPriceSource} from "../src/PriceSources.sol";
import {MockERC20} from "./Mocks.sol";

/// A real xyz:NVDA round on HyperEVM, replayed from values recorded live with
/// script/record_hip3.py on Sunday 2026-11-15 (the price precompiles cannot be read for a past
/// block). The round started at 04:45:00 UTC (1794717900). The first blocks at or after the start
/// and the end were 51301960 and 51302265.
///
/// US stocks were closed. trade.xyz's oracle changed twice in the six minutes recorded, and the
/// round opened and closed at 161.110 while the book moved: an equal price, so the round is void
/// and every stake goes back. Over 353 samples the spread was at most 3.11 bps, the mark at most
/// 3.72 bps from the oracle and the mid at most 11.79 bps.
contract Hip3RecordedTest is Test {
    uint64 constant T = 1794717900;
    uint32 constant DEX = 1; // xyz
    uint32 constant INDEX = 2; // xyz:NVDA
    uint8 constant SZ = 3;
    uint256 constant ASSET = 1;

    Hip3Source src;
    FiveMin fm;
    MockERC20 usd;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(T - 30);
        src = new Hip3Source(20, 50, 50);
        usd = new MockERC20();
        fm = new FiveMin(makeAddr("treasury"));
        fm.list(
            ASSET,
            FiveMin.Listing({
                source: IPriceSource(address(src)),
                feed: src.feedOf(DEX, INDEX, SZ),
                token: IERC20(address(usd)),
                maxDelay: 3,
                feeBps: 200,
                minStake: 1e6,
                paused: false
            })
        );
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; i++) {
            usd.mint(who[i], 100e6);
            vm.prank(who[i]);
            usd.approve(address(fm), type(uint256).max);
        }
    }

    /// The recorded block: raw precompile values in 6 - szDecimals = 3 decimals.
    function _block(uint64 ts, uint64 oracle, uint64 mark, uint64 bid, uint64 ask) internal {
        vm.warp(ts);
        uint32 perp = HLPrecompiles.perpIndex(DEX, INDEX);
        vm.mockCall(HLPrecompiles.ORACLE_PX, abi.encode(perp), abi.encode(oracle));
        vm.mockCall(HLPrecompiles.MARK_PX, abi.encode(perp), abi.encode(mark));
        vm.mockCall(HLPrecompiles.BBO, abi.encode(HLPrecompiles.bboIndex(DEX, INDEX)), abi.encode(bid, ask));
    }

    function test_recordedSundayRound_equalOracle_isVoid() public {
        vm.prank(alice);
        fm.bet(ASSET, T, true, 50e6);
        vm.prank(bob);
        fm.bet(ASSET, T, false, 30e6);

        _block(T, 161_110, 161_100, 161_100, 161_110); // block 51301960
        fm.poke(ASSET, T);
        _block(T + 300, 161_110, 161_140, 161_190, 161_200); // block 51302265
        fm.poke(ASSET, T);

        (,, uint256 openPx, uint256 closePx, uint64 openAt, uint64 closeAt,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openPx, 161.11e18);
        assertEq(closePx, 161.11e18);
        assertEq(openAt, T);
        assertEq(closeAt, T + 300);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
        console2.log(
            "xyz:NVDA open %s / 1000 at the start, close %s / 1000 at the end: equal, so the round is void",
            openPx / 1e15,
            closePx / 1e15
        );
        vm.prank(alice);
        assertEq(fm.claim(ASSET, T), 50e6);
        vm.prank(bob);
        assertEq(fm.claim(ASSET, T), 30e6);
        assertEq(fm.collectFee(ASSET, T), 0);
        console2.log("every stake back: alice 50, bob 30; no fee");
    }
}
