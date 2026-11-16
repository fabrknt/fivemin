# fivemin

Five-minute up-or-down pools. Stakes go on Up or Down **before** a round starts; when it ends, the
side that was right shares the other side's stakes, less a fee. Nobody takes the other side of a
bet. The two prices are the first readings at or after the round's start and end, from a feed
already on the chain, and never change once recorded. Spec: [docs/spec.md](docs/spec.md).

| source | chain | assets |
|---|---|---|
| `PythPushSource` | Monad mainnet | Pyth's sponsored push feeds: BTC, ETH, SOL, MON (0.02% deviation) |
| `Hip3Source` | HyperEVM | a Hyperliquid perp's oracle, precompile 0x807 (HIP-3: set by the deployer) |

Status: draft, not audited, not deployed. Tested on a Monad mainnet fork with a real round: BTC,
2026-11-15 03:25 UTC, recorded at Pyth's first updates after the start ($64,725.57) and the end
($64,634.06), Down won.

```sh
forge test            # unit tests, the HIP-3 source with a mocked precompile, and the Monad fork round
unproven unproven.toml   # delete each check in turn: which test notices (about 10 minutes)
```

Uses [hl-price-guard](https://github.com/fabrknt/hl-price-guard) v0.4.1 (`PythRef`, `HLPriceGuard`).

Walk through it: the recipe [Open a five-minute up-or-down market](https://fabrknt.com/recipes/five-minute-market)
(about 10 minutes), and the Dojo topic [Settle at a set time from a price already on chain](https://fabrknt.com/dojo/topics/settle-at-a-set-time).

## Written with AI

Claude (Opus 5.5) wrote all of it, in one session on 2026-11-15: the spec, the two contracts
(319 lines) and the tests (662 lines); every commit names it as co-author. A person chose the
design (stakes close at the start, first reading after each checkpoint) and the checks. What was
used to check it, and what it found:

| check | result |
|---|---|
| A real round on a Monad mainnet fork | the recorded prices are Pyth's first updates after the start and end, read independently from `PriceFeedUpdate` logs |
| Unit tests, and a fuzz test of the payout (1,000 runs) | pass; the fuzz test is what states "a winner never gets less than their stake" |
| Codex review r1 | CHANGES: a late poke could rewrite a void round, a reading ahead of the block was accepted, HIP-3 allowed a 299 s window, fee-on-transfer tokens; all fixed with a test each. One blocker is open (below) |
| [unproven](https://github.com/fabrknt/unproven): delete each of the 38 checks in `FiveMin.sol` in turn | first run: 20 caught by a test, **18 caught by nothing**, as predicted row for row. Three of those would have lost money if the check were gone (a fee taken from a round still pending, a fee taken from a void round, a Down-only round won by Up paying no one). 11 tests added; now 31 caught, 7 unproven, each with the reason it is not a hole in [`unproven.toml`](unproven.toml). 2026-11-16: two more checks listed (a recorded open or close never changes); deleting the close's had failed no test, so a test was added: 40 checks, 33 caught, 7 unproven |

**Open blocker (review r1):** with Pyth, anyone holding signed Pyth updates can push the most
favourable price inside a checkpoint's window before the sponsored pusher does, then poke. See
[docs/spec.md](docs/spec.md). Not for real money until it is closed.

What has not been done: an audit and a mainnet deployment. The Monad fork test is not in the
unproven table (it needs the network).

## License

Apache-2.0
