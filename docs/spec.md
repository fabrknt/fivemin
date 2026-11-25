# fivemin: five-minute up-or-down pools

Spec r3, 2026-11-15. Status: draft. Codex review r1: CHANGES, fixed in r2. r3: HIP-3 first (decided
2026-11-15); the Pyth source stays for Monad but is not for real money until its blocker is closed.

## What it is

Every five minutes, for each listed asset, a round: will the price at the end of the five minutes be
above or below the price at its start? People (and AI agents) put a stake on Up or Down **before the
round starts**. When it ends, the side that was right shares the other side's stakes, less a fee.
Nobody takes the other side of a bet, so there is no house to drain and no market maker to fund.

The price comes from a feed already on the chain, read for free:

| chain | source | assets | update |
|---|---|---|---|
| Monad | Pyth sponsored push feeds, `getPriceUnsafe` | BTC, ETH, SOL, MON (premium) | 0.02% move or 1 h; BTC measured 2026-11-15: median 17 s, p90 50 s, max 90 s |
| HyperEVM | HIP-3 oracle, precompile `0x807`, accepted only while the mark and the book agree with it (`HLPriceGuard.read`) | perps such as `xyz:NVDA` | set by the market's deployer |

Order: **HIP-3 first.** Nobody else can push a price into HyperCore's oracle, so the only choice
left to a poker is the block inside a 3 s window. The Monad source has an open blocker (below)
that needs Pyth's first-update-after-a-time check, which needs a Pyth API key; until then it is
for testing only.

## Rounds

- A round is `(assetId, startTime)`, with `startTime` a multiple of 300 s. It needs no creation
  step: the first bet makes it exist.
- `endTime = startTime + 300`.
- Bets are taken while `block.timestamp < startTime`, and no earlier than `startTime - 3600`.

## The two prices: first observation, then fixed

The contract cannot see a feed's history, only its value now. If the settler chose when to read,
they could wait for a price that suits them. So each of the two checkpoints (`startTime`,
`endTime`) takes the **first observation recorded at or after it**, and records it for good:

- `poke(assetId, startTime)` reads the source and, for each checkpoint not yet recorded, records the
  reading if it is admissible for that checkpoint. Anyone may call it; the operator's keeper calls it
  every block after each checkpoint.
- Admissible for checkpoint `T`, all of: the block is in `[T, T + maxDelay]`; the reading's time is
  in `[T, T + maxDelay]`; the reading's time is not ahead of the block.
  - Pyth: the reading's time is its `publishTime`; price > 0; confidence within the source's
    `maxConfBps` (one per deployed `PythPushSource`, shared by its listings).
  - HIP-3: the reading's time is the block's; oracle > 0.
- A checkpoint is shared: round `S`'s close and round `S + 300`'s open are the same moment. One
  poke records the reading in both (where each has stakes and is not yet recorded), so the two
  never get different prices. Found by the TLA+ model (`formal/`); before this each round was
  recorded by its own poke and could take a different block's price.
- After `T + maxDelay` nothing is recorded for `T`, so a round that is Void stays Void.
- A recorded price never changes.
- `maxDelay` is capped by the source: 120 s for Pyth push (the longest gap measured on Monad was
  90 s), 3 s for HIP-3 (each block in the window is a price the poker could pick).

What this leaves open, stated plainly:
- **Pyth, open blocker (review r1):** anyone holding signed Pyth updates (Hermes) can push one with a
  `publishTime` in the window before the sponsored pusher does, then poke. They can pick the most
  favourable signed price in `[T, T + maxDelay]`. Pyth stores only an update newer than the stored
  one, so the choice is among prices published after the last stored push. Closing it needs either
  Pyth's `parsePriceFeedUpdatesUnique` (the first update after `T`, which takes updates from
  Hermes, i.e. an API key) or a window short enough that the choice is worth little. Not decided.
- **Pyth:** if two pushes land after `T` before anyone pokes, the later one is recorded. The side
  the earlier push favoured had every reason to poke at once; the keeper pokes each block.
- **HIP-3:** the price is the oracle in the block of the first poke, any block in `[T, T + 3 s]`.
  The deployer sets the oracle. There is no free outside price for it, so `Hip3Source` refuses a
  reading whose spread, mark or mid is further from the oracle than its bounds (set at deployment
  from measured values). The deployer can still move oracle, mark and book together by trading;
  this narrows what the deployer alone can do, it does not remove it. The listing says so.
- **HIP-3 history:** the price precompiles answer with the current state whatever block a call
  names (checked 2026-11-15), so a past round cannot be re-read; rounds are recorded as they
  happen (`script/record_hip3.py`).
- **HIP-3 stocks outside market hours:** on Sunday 2026-11-15 xyz:NVDA's oracle changed twice in
  six minutes while its book moved, and a recorded round opened and closed at 161.110 (void,
  `test/Hip3Recorded.t.sol`). A stock listing is worth running only while its market is open;
  how often the oracle moves then is to be measured (a round recorded in US hours).

## Outcome

- If either checkpoint has no admissible reading by `T + maxDelay`: **void**, every stake back.
- If one side has no stakes: **void**.
- `close > open`: Up wins. `close < open`: Down wins. `close == open`: **void**.
- Winners split the losing side's stakes in proportion to their own stake, after a fee of
  `feeBps` taken from the losing side only. A winner always gets at least their stake back.
- Payment is claimed (`claim`), not pushed. Rounding dust stays in the contract with the fee.

## Assets

- The owner lists an asset once: source, feed (Pyth id or HIP-3 perp), `maxDelay`, stake token,
  minimum stake. The stake token must have code, and every transfer must move exactly the amount
  (a fee-on-transfer or rebasing token is refused at the first bet). A listing cannot be changed afterwards, so a round's rules are fixed
  when its first bet is placed. The owner can stop new bets on an asset (not existing rounds).
- The fee goes to the treasury at the time it is collected (never the zero address). `feeBps` is
  fixed per listing, at most 500. Ownership moves in two steps (transfer, then accept).

## Not in scope

- Running AI agents (they are ordinary bettors, off-chain).
- Any custody beyond the round's stakes; the contract holds nothing else.
- Real-money deployment. Built and tested against a Monad mainnet fork first. Who operates it and
  where it is blocked is decided before any mainnet deployment.

## Tests that must pass

1. A full round on a Monad mainnet fork with real Pyth BTC pushes: bets before the start, the first
   push after `startTime` and after `endTime` recorded, winners paid, losers' stakes less the fee.
2. A reading published before `T`, or after `T + maxDelay`, is not recorded.
3. A second poke after a recorded checkpoint changes nothing.
4. Void on: a missed checkpoint, a one-sided round, an equal price.
5. Bets refused at or after `startTime`, and before `startTime - 3600`.
6. Payout sums never exceed the stakes; a winner never gets less than their stake.
7. The HIP-3 source with a mocked precompile: the window rule above.
8. A round's close and the next round's open get the same reading, whichever round is poked first.
9. The TLA+ model (`formal/`) holds its safety properties under TLC on both sources.
