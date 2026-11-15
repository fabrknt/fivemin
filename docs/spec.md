# fivemin: five-minute up-or-down pools

Spec r1, 2026-11-15. Status: draft, not reviewed.

## What it is

Every five minutes, for each listed asset, a round: will the price at the end of the five minutes be
above or below the price at its start? People (and AI agents) put a stake on Up or Down **before the
round starts**. When it ends, the side that was right shares the other side's stakes, less a fee.
Nobody takes the other side of a bet, so there is no house to drain and no market maker to fund.

The price comes from a feed already on the chain, read for free:

| chain | source | assets | update |
|---|---|---|---|
| Monad | Pyth sponsored push feeds, `getPriceUnsafe` | BTC, ETH, SOL, MON (premium) | 0.02% move or 1 h; BTC measured 2026-11-15: median 17 s, p90 50 s, max 90 s |
| HyperEVM | HIP-3 oracle, precompile `0x807` (via hl-price-guard) | perps such as `xyz:NVDA` | set by the market's deployer |

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
- Admissible for checkpoint `T`:
  - Pyth: `publishTime >= T` and `publishTime <= T + maxDelay`, price > 0, confidence within
    `maxConfBps`. The reading's time is its `publishTime`.
  - HIP-3: `block.timestamp >= T` and `block.timestamp <= T + maxDelay`, oracle > 0. The reading's
    time is the block's.
- A recorded price never changes.

What this leaves open, stated plainly:
- **Pyth:** if two pushes land after `T` before anyone pokes, the later one is recorded. The side
  the earlier push favoured had every reason to poke at once; the keeper pokes each block. Pushes
  are about 17 s apart and blocks 0.4 s, so the gap is small but not zero.
- **HIP-3:** the price is the oracle in the block of the first poke. A poker can choose any block in
  `[T, T + maxDelay]`, so `maxDelay` is kept to a few seconds. The deployer sets the oracle; the
  asset's listing says so.

## Outcome

- If either checkpoint has no admissible reading by `T + maxDelay`: **void**, every stake back.
- If one side has no stakes: **void**.
- `close > open`: Up wins. `close < open`: Down wins. `close == open`: **void**.
- Winners split the losing side's stakes in proportion to their own stake, after a fee of
  `feeBps` taken from the losing side only. A winner always gets at least their stake back.
- Payment is claimed (`claim`), not pushed. Rounding dust stays in the contract with the fee.

## Assets

- The owner lists an asset once: source, feed (Pyth id or HIP-3 perp), `maxDelay`, `maxConfBps`,
  stake token, minimum stake. A listing cannot be changed afterwards, so a round's rules are fixed
  when its first bet is placed. The owner can stop new bets on an asset (not existing rounds).
- The fee goes to a treasury address set by the owner. `feeBps` is fixed per listing, at most 500.

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
