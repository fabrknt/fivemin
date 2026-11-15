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
```

Uses [hl-price-guard](https://github.com/fabrknt/hl-price-guard) v0.4.1 (`PythRef`, `HLPriceGuard`).

## Written with AI

Claude (Opus 5.5) wrote all of it, in one session on 2026-11-15: the spec, the two contracts
(277 lines) and the tests (441 lines); every commit names it as co-author. A person chose the
design (stakes close at the start, first reading after each checkpoint) and the checks. What was
used to check it, and what it found:

| check | result |
|---|---|
| A real round on a Monad mainnet fork | the recorded prices are Pyth's first updates after the start and end, read independently from `PriceFeedUpdate` logs |
| Unit tests, and a fuzz test of the payout (1,000 runs) | pass; the fuzz test is what states "a winner never gets less than their stake" |
| Codex review | pending |

What has not been done: an audit, a mainnet deployment, and a measurement of which checks a test
would notice if deleted ([unproven](https://github.com/fabrknt/unproven) does not read Foundry's
test output yet).

## License

Apache-2.0
