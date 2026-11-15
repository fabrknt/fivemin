// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "hl-price-guard/src/HLPrecompiles.sol";
import {HLPriceGuard} from "hl-price-guard/src/HLPriceGuard.sol";
import {FiveMin, IERC20} from "../src/FiveMin.sol";
import {Hip3Source, IPriceSource} from "../src/PriceSources.sol";
import {MockERC20} from "./Mocks.sol";

/// The HIP-3 source with the price precompiles mocked: a reading's time is the block's, so the
/// window rule decides which blocks may set a checkpoint, and a reading whose book disagrees with
/// the oracle is refused.
contract Hip3SourceTest is Test {
    Hip3Source src;
    FiveMin fm;
    MockERC20 usd;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint64 constant T = 1_800_000_000;
    uint32 constant DEX = 1; // xyz
    uint32 constant INDEX = 2; // xyz:NVDA
    uint8 constant SZ = 3;
    uint256 constant ASSET = 9;

    function setUp() public {
        vm.warp(T - 60);
        src = new Hip3Source(20, 50, 50);
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

    /// Raw precompile values, in 6 - szDecimals = 3 decimals.
    function _book(uint64 oracle, uint64 mark, uint64 bid, uint64 ask) internal {
        uint32 perp = HLPrecompiles.perpIndex(DEX, INDEX);
        vm.mockCall(HLPrecompiles.ORACLE_PX, abi.encode(perp), abi.encode(oracle));
        vm.mockCall(HLPrecompiles.MARK_PX, abi.encode(perp), abi.encode(mark));
        vm.mockCall(HLPrecompiles.BBO, abi.encode(HLPrecompiles.bboIndex(DEX, INDEX)), abi.encode(bid, ask));
    }

    function test_feedPacksThePerp_andScales() public {
        _book(161_110, 161_100, 161_100, 161_110);
        (uint256 px, uint64 at) = src.read(src.feedOf(DEX, INDEX, SZ));
        assertEq(px, 161.11e18);
        assertEq(at, block.timestamp);
    }

    function test_onlyBlocksInsideTheWindowSetACheckpoint() public {
        vm.prank(alice);
        fm.bet(ASSET, T, true, 10);
        vm.prank(bob);
        fm.bet(ASSET, T, false, 10);

        _book(161_110, 161_100, 161_100, 161_110);
        vm.warp(T - 1);
        fm.poke(ASSET, T); // before the start: nothing
        vm.warp(T + 4);
        fm.poke(ASSET, T); // after T + maxDelay: nothing
        (,,,, uint64 openAt,,) = fm.rounds(fm.key(ASSET, T));
        assertEq(openAt, 0);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Void));
    }

    /// An oracle the book does not agree with is not a price: a deployer moving the oracle alone
    /// leaves the checkpoint unrecorded, and the round void.
    function test_oracleAwayFromTheBook_isRefused() public {
        _book(170_000, 161_100, 161_100, 161_110); // mark 5.24% below the oracle (measured against the oracle)
        bytes32 feed = src.feedOf(DEX, INDEX, SZ);
        vm.expectRevert(
            abi.encodeWithSelector(HLPriceGuard.PriceRejected.selector, HLPriceGuard.Breach.MarkOracle, 524, 50)
        );
        src.read(feed);
    }

    function test_wideSpread_isRefused() public {
        _book(161_110, 161_100, 160_000, 162_000); // 125 bps wide
        bytes32 feed = src.feedOf(DEX, INDEX, SZ);
        vm.expectRevert(
            abi.encodeWithSelector(HLPriceGuard.PriceRejected.selector, HLPriceGuard.Breach.Spread, 125, 20)
        );
        src.read(feed);
    }

    function test_emptyBookOrZeroOracle_isRefused() public {
        _book(0, 161_100, 161_100, 161_110);
        bytes32 feed = src.feedOf(DEX, INDEX, SZ); // outside expectRevert, which watches the next call
        vm.expectRevert(
            abi.encodeWithSelector(HLPriceGuard.PriceRejected.selector, HLPriceGuard.Breach.EmptyBook, 0, 0)
        );
        src.read(feed);
    }
}
