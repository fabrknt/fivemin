// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IPriceSource} from "./PriceSources.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// Five-minute up-or-down pools (docs/spec.md). Stakes go on Up or Down before a round starts; the
/// side that was right shares the other side's stakes, less a fee. A round's two prices are the
/// first admissible readings recorded at or after its start and its end, and never change.
contract FiveMin {
    uint64 public constant ROUND = 300;
    uint64 public constant BETS_OPEN = 3600; // bets open this long before a round starts
    uint16 public constant MAX_FEE_BPS = 500;

    struct Listing {
        IPriceSource source;
        bytes32 feed;
        IERC20 token;
        uint64 maxDelay; // a reading counts for checkpoint T only if its time is in [T, T + maxDelay]
        uint16 feeBps; // taken from the losing side
        uint128 minStake;
        bool paused; // no new bets; rounds already bet on run to the end
    }

    struct Round {
        uint256 up;
        uint256 down;
        uint256 openPx;
        uint256 closePx;
        uint64 openAt;
        uint64 closeAt;
        bool feeCollected;
    }

    enum Outcome {
        Pending,
        Void,
        Up,
        Down
    }

    address public owner;
    address public treasury;
    mapping(uint256 assetId => Listing) public listings;
    mapping(bytes32 roundKey => Round) public rounds;
    mapping(bytes32 roundKey => mapping(address => uint256[2])) public stakes; // [down, up]
    mapping(bytes32 roundKey => mapping(address => bool)) public claimed;

    event Listed(uint256 indexed assetId, address source, bytes32 feed, address token, uint64 maxDelay, uint16 feeBps);
    event Paused(uint256 indexed assetId, bool paused);
    event Bet(uint256 indexed assetId, uint64 indexed startTime, address indexed who, bool up, uint256 amount);
    event Recorded(uint256 indexed assetId, uint64 indexed startTime, bool close, uint256 price, uint64 at);
    event Claimed(uint256 indexed assetId, uint64 indexed startTime, address indexed who, uint256 amount);
    event FeeCollected(uint256 indexed assetId, uint64 indexed startTime, uint256 amount);

    error NotOwner();
    error AlreadyListed(uint256 assetId);
    error NotListed(uint256 assetId);
    error BadListing();
    error IsPaused(uint256 assetId);
    error BadStartTime(uint64 startTime);
    error BetsClosed(uint64 startTime);
    error BetsNotOpen(uint64 startTime);
    error StakeTooSmall(uint256 amount, uint256 minStake);
    error NotFinal();
    error AlreadyClaimed();
    error NothingToClaim();
    error TransferFailed();

    constructor(address treasury_) {
        owner = msg.sender;
        treasury = treasury_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---- owner ----

    /// Lists an asset once. A listing cannot be changed, so a round's rules are fixed from its
    /// first bet; only new bets can be stopped (`setPaused`).
    function list(uint256 assetId, Listing calldata l) external onlyOwner {
        if (address(listings[assetId].source) != address(0)) revert AlreadyListed(assetId);
        if (
            address(l.source) == address(0) || address(l.token) == address(0) || l.maxDelay == 0 || l.maxDelay >= ROUND
                || l.feeBps > MAX_FEE_BPS || l.minStake == 0
        ) revert BadListing();
        listings[assetId] = l;
        listings[assetId].paused = false;
        emit Listed(assetId, address(l.source), l.feed, address(l.token), l.maxDelay, l.feeBps);
    }

    function setPaused(uint256 assetId, bool paused) external onlyOwner {
        _listing(assetId).paused = paused;
        emit Paused(assetId, paused);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
    }

    function setOwner(address owner_) external onlyOwner {
        owner = owner_;
    }

    // ---- bettors ----

    function bet(uint256 assetId, uint64 startTime, bool up, uint256 amount) external {
        Listing storage l = _listing(assetId);
        if (l.paused) revert IsPaused(assetId);
        if (startTime % ROUND != 0) revert BadStartTime(startTime);
        if (block.timestamp >= startTime) revert BetsClosed(startTime);
        if (block.timestamp + BETS_OPEN < startTime) revert BetsNotOpen(startTime);
        if (amount < l.minStake) revert StakeTooSmall(amount, l.minStake);

        bytes32 k = key(assetId, startTime);
        Round storage r = rounds[k];
        if (up) r.up += amount;
        else r.down += amount;
        stakes[k][msg.sender][up ? 1 : 0] += amount;
        _pull(l.token, msg.sender, amount);
        emit Bet(assetId, startTime, msg.sender, up, amount);
    }

    /// Records the current reading for each checkpoint it is admissible for and that is not yet
    /// recorded. Anyone may call; a recorded price never changes.
    function poke(uint256 assetId, uint64 startTime) external {
        Listing storage l = _listing(assetId);
        bytes32 k = key(assetId, startTime);
        Round storage r = rounds[k];
        if (r.up == 0 && r.down == 0) return; // no bets, nothing to settle
        (uint256 px, uint64 at) = l.source.read(l.feed);
        if (r.openAt == 0 && _admissible(at, startTime, l.maxDelay)) {
            r.openPx = px;
            r.openAt = at;
            emit Recorded(assetId, startTime, false, px, at);
        }
        uint64 endTime = startTime + ROUND;
        if (r.closeAt == 0 && _admissible(at, endTime, l.maxDelay)) {
            r.closePx = px;
            r.closeAt = at;
            emit Recorded(assetId, startTime, true, px, at);
        }
    }

    function claim(uint256 assetId, uint64 startTime) external returns (uint256 amount) {
        Listing storage l = _listing(assetId);
        bytes32 k = key(assetId, startTime);
        if (claimed[k][msg.sender]) revert AlreadyClaimed();
        amount = payout(assetId, startTime, msg.sender);
        if (amount == 0) revert NothingToClaim();
        claimed[k][msg.sender] = true;
        _push(l.token, msg.sender, amount);
        emit Claimed(assetId, startTime, msg.sender, amount);
    }

    /// Sends a resolved round's fee to the treasury, once. Anyone may call.
    function collectFee(uint256 assetId, uint64 startTime) external returns (uint256 fee) {
        Listing storage l = _listing(assetId);
        bytes32 k = key(assetId, startTime);
        Round storage r = rounds[k];
        Outcome o = outcome(assetId, startTime);
        if (o == Outcome.Pending) revert NotFinal();
        if (r.feeCollected || o == Outcome.Void) return 0;
        r.feeCollected = true;
        fee = ((o == Outcome.Up ? r.down : r.up) * l.feeBps) / 10_000;
        if (fee != 0) _push(l.token, treasury, fee);
        emit FeeCollected(assetId, startTime, fee);
    }

    // ---- views ----

    function key(uint256 assetId, uint64 startTime) public pure returns (bytes32) {
        return keccak256(abi.encode(assetId, startTime));
    }

    function outcome(uint256 assetId, uint64 startTime) public view returns (Outcome) {
        Listing storage l = listings[assetId];
        Round storage r = rounds[key(assetId, startTime)];
        uint64 endTime = startTime + ROUND;
        // A checkpoint with no admissible reading by T + maxDelay voids the round.
        if (r.openAt == 0) return block.timestamp > startTime + l.maxDelay ? Outcome.Void : Outcome.Pending;
        if (r.closeAt == 0) return block.timestamp > endTime + l.maxDelay ? Outcome.Void : Outcome.Pending;
        if (r.up == 0 || r.down == 0 || r.closePx == r.openPx) return Outcome.Void;
        return r.closePx > r.openPx ? Outcome.Up : Outcome.Down;
    }

    /// What `who` can claim once the round is final (0 while pending, after claiming, or on the
    /// losing side). A winner gets their stake plus their share of the losing side, less the fee.
    function payout(uint256 assetId, uint64 startTime, address who) public view returns (uint256) {
        bytes32 k = key(assetId, startTime);
        if (claimed[k][who]) return 0;
        Outcome o = outcome(assetId, startTime);
        uint256[2] storage s = stakes[k][who];
        if (o == Outcome.Pending) return 0;
        if (o == Outcome.Void) return s[0] + s[1];
        Round storage r = rounds[k];
        (uint256 mine, uint256 winners, uint256 losers) = o == Outcome.Up ? (s[1], r.up, r.down) : (s[0], r.down, r.up);
        if (mine == 0) return 0;
        uint256 pot = losers - (losers * listings[assetId].feeBps) / 10_000;
        return mine + (mine * pot) / winners;
    }

    // ---- internal ----

    function _listing(uint256 assetId) private view returns (Listing storage l) {
        l = listings[assetId];
        if (address(l.source) == address(0)) revert NotListed(assetId);
    }

    function _admissible(uint64 at, uint64 t, uint64 maxDelay) private view returns (bool) {
        return block.timestamp >= t && at >= t && at <= t + maxDelay;
    }

    function _pull(IERC20 token, address from, uint256 amount) private {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _push(IERC20 token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
