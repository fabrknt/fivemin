// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FiveMinTest} from "./FiveMin.t.sol";
import {FiveMin} from "../src/FiveMin.sol";

/// Found by the TLA+ model (formal/, `SharedCheckpoint`): round T's close and round T+300's open are
/// the same checkpoint. Before the fix each was recorded by its own poke, so a poke of round T at
/// T+301 and a poke of round T+300 at T+340 recorded 101 and 99 for the same moment.
contract TlaSharedCheckpointTest is FiveMinTest {
    uint64 constant T2 = T + 300;

    function _betBoth() internal {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.prank(alice);
        fm.bet(ASSET, T2, true, 10e6);
        vm.prank(bob);
        fm.bet(ASSET, T2, false, 10e6);
        vm.warp(T + 1);
        src.set(100e18, T + 1);
        fm.poke(ASSET, T);
    }

    function _shared() internal view returns (uint256 close1, uint64 closeAt1, uint256 open2, uint64 openAt2) {
        (,,, close1,, closeAt1,) = fm.rounds(fm.key(ASSET, T));
        (,, open2,, openAt2,,) = fm.rounds(fm.key(ASSET, T2));
    }

    function test_sharedCheckpoint_pokeEndingRound_recordsNextOpen() public {
        _betBoth();
        vm.warp(T2 + 1);
        src.set(101e18, T2 + 1);
        fm.poke(ASSET, T);
        vm.warp(T2 + 40);
        src.set(99e18, T2 + 40);
        fm.poke(ASSET, T2); // changes nothing: the checkpoint is already recorded
        (uint256 close1, uint64 closeAt1, uint256 open2, uint64 openAt2) = _shared();
        assertEq(close1, 101e18);
        assertEq(open2, 101e18);
        assertEq(closeAt1, T2 + 1);
        assertEq(openAt2, T2 + 1);
    }

    function test_sharedCheckpoint_pokeStartingRound_recordsPreviousClose() public {
        _betBoth();
        vm.warp(T2 + 1);
        src.set(99e18, T2 + 1);
        fm.poke(ASSET, T2);
        vm.warp(T2 + 40);
        src.set(101e18, T2 + 40);
        fm.poke(ASSET, T); // changes nothing
        (uint256 close1,, uint256 open2,) = _shared();
        assertEq(close1, 99e18);
        assertEq(open2, 99e18);
        assertEq(uint256(fm.outcome(ASSET, T)), uint256(FiveMin.Outcome.Down));
    }

    /// A neighbour with no bets is left alone.
    function test_sharedCheckpoint_emptyNeighbourUntouched() public {
        _bet(alice, true, 10e6);
        _bet(bob, false, 10e6);
        vm.warp(T + 1);
        src.set(100e18, T + 1);
        fm.poke(ASSET, T);
        vm.warp(T2 + 1);
        src.set(101e18, T2 + 1);
        fm.poke(ASSET, T);
        (, uint64 closeAt1,, uint64 openAt2) = _shared();
        assertEq(closeAt1, T2 + 1);
        assertEq(openAt2, 0);
        (,,,, uint64 prevOpenAt,,) = fm.rounds(fm.key(ASSET, T - 300));
        assertEq(prevOpenAt, 0);
    }
}
