// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HLPriceGuard} from "hl-price-guard/src/HLPriceGuard.sol";
import {IPyth, PythRef} from "hl-price-guard/src/PythRef.sol";

/// A price read now, and the time it is a price for. Reverts when there is no usable price.
interface IPriceSource {
    /// `price` in 1e18; `at` in unix seconds.
    function read(bytes32 feed) external view returns (uint256 price, uint64 at);

    /// The longest checkpoint window a listing on this source may use.
    function maxDelayLimit() external view returns (uint64);
}

/// Pyth's stored price, as pushed by Pyth's sponsored feeds (Monad mainnet: BTC, ETH, SOL and MON
/// on a 0.02% deviation). `at` is the update's publishTime, so a reading is placed by when Pyth
/// published it, not by when someone read it. `feed` is the Pyth price id.
contract PythPushSource is IPriceSource {
    IPyth public immutable pyth;
    uint16 public immutable maxConfBps;

    constructor(IPyth pyth_, uint16 maxConfBps_) {
        pyth = pyth_;
        maxConfBps = maxConfBps_;
    }

    /// The longest gap between Monad's BTC pushes measured on 2026-11-15 was 90 s.
    function maxDelayLimit() external pure returns (uint64) {
        return 120;
    }

    function read(bytes32 feed) external view returns (uint256 price, uint64 at) {
        HLPriceGuard.Ref memory r = PythRef.read(pyth, feed, 0, maxConfBps);
        return (r.price, uint64(r.updatedAt));
    }
}

/// A Hyperliquid perp's oracle, read on HyperEVM through precompile 0x807, accepted only while the
/// book agrees with it. For a HIP-3 market the deployer sets the oracle, and there is no free
/// outside price to compare it with; the mark and the book are the next best thing, because the
/// deployer cannot move them without trading. HLPriceGuard.read rejects a reading whose spread, mark
/// or mid is further from the oracle than `bounds` allows, and then nothing is recorded: a
/// checkpoint left without a reading voids the round. The oracle carries no time of its own, so
/// `at` is the block's: whoever calls chooses the block, which is why the window stays short.
/// `feed` packs the perp: `dex << 40 | index << 8 | szDecimals`.
contract Hip3Source is IPriceSource {
    uint16 public immutable maxSpreadBps;
    uint16 public immutable maxMarkOracleBps;
    uint16 public immutable maxMidOracleBps;

    constructor(uint16 maxSpreadBps_, uint16 maxMarkOracleBps_, uint16 maxMidOracleBps_) {
        require(maxSpreadBps_ != 0 && maxMarkOracleBps_ != 0 && maxMidOracleBps_ != 0, "bounds");
        maxSpreadBps = maxSpreadBps_;
        maxMarkOracleBps = maxMarkOracleBps_;
        maxMidOracleBps = maxMidOracleBps_;
    }

    /// Each block in the window is a price the poker could pick; a few blocks at most.
    function maxDelayLimit() external pure returns (uint64) {
        return 3;
    }

    function read(bytes32 feed) external view returns (uint256 price, uint64 at) {
        uint256 f = uint256(feed);
        HLPriceGuard.Asset memory a =
            HLPriceGuard.Asset({dex: uint32(f >> 40), index: uint32(f >> 8), szDecimals: uint8(f)});
        HLPriceGuard.Bounds memory b = HLPriceGuard.Bounds({
            maxMarkOracleBps: maxMarkOracleBps,
            maxMidOracleBps: maxMidOracleBps,
            maxSpreadBps: maxSpreadBps,
            maxRefOracleBps: 0
        });
        HLPriceGuard.Ref memory none; // no outside reference: the book is the check
        return (HLPriceGuard.read(a, b, none), uint64(block.timestamp));
    }

    function feedOf(uint32 dex, uint32 index, uint8 szDecimals) external pure returns (bytes32) {
        return bytes32((uint256(dex) << 40) | (uint256(index) << 8) | szDecimals);
    }
}
