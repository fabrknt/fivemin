// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "hl-price-guard/src/HLPrecompiles.sol";
import {FiveMin, IERC20} from "../src/FiveMin.sol";
import {Hip3Source, IPriceSource} from "../src/PriceSources.sol";
import {MockERC20} from "./Mocks.sol";

/// The HIP-3 source with precompile 0x807 mocked: a reading's time is the block's, so the window
/// rule decides which blocks may set a checkpoint.
contract Hip3SourceTest is Test {
    Hip3Source src;
    FiveMin fm;
    MockERC20 usd;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint64 constant T = 1_800_000_000;
    uint32 constant DEX = 1; // e.g. xyz
    uint32 constant INDEX = 7;
    uint8 constant SZ = 3;
    uint256 constant ASSET = 9;

    function setUp() public {
        vm.warp(T - 60);
        src = new Hip3Source();
        usd = new MockERC20();
        fm = new FiveMin(address(this));
        fm.list(
            ASSET,
            FiveMin.Listing({
                source: IPriceSource(address(src)),
                feed: src.feedOf(DEX, INDEX, SZ),
                token: IERC20(address(usd)),
                maxDelay: 3,
                feeBps: 0,
                minStake: 1,
                paused: false
            })
        );
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; i++) {
            usd.mint(who[i], 100);
            vm.prank(who[i]);
            usd.approve(address(fm), type(uint256).max);
        }
    }

    function _oracle(uint64 raw) internal {
        vm.mockCall(HLPrecompiles.ORACLE_PX, abi.encode(HLPrecompiles.perpIndex(DEX, INDEX)), abi.encode(raw));
    }

    function test_feedPacksThePerp_andScales() public {
        _oracle(185_250); // 185.250 with 6 - szDecimals = 3 decimals
        (uint256 px, uint64 at) = src.read(src.feedOf(DEX, INDEX, SZ));
        assertEq(px, 185.25e18);
        assertEq(at, block.timestamp);
    }

    function test_onlyBlocksInsideTheWindowSetACheckpoint() public {
        vm.prank(alice);
        fm.bet(ASSET, T, true, 10);
        vm.prank(bob);
        fm.bet(ASSET, T, false, 10);

        _oracle(100_000);
        vm.warp(T - 1);
        fm.poke(ASSET, T); // before the start: nothing
        vm.warp(T + 4);
        fm.poke(ASSET, T); // after T + maxDelay: nothing
        (,,,, uint64 openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openAt, 0);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
    }

    function test_zeroOracleReverts() public {
        _oracle(0);
        bytes32 feed = src.feedOf(DEX, INDEX, SZ); // outside expectRevert, which watches the next call
        vm.expectRevert();
        src.read(feed);
    }
}
