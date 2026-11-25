# formal: a TLA+ model of FiveMin

`FiveMin.tla` models `src/FiveMin.sol` (rounds, bets, `poke`, `outcome`, `claim`, `collectFee`)
with two price sources: HIP-3 (a reading's time is the block's) and Pyth push (a stored reading;
anyone may push a newer signed update). Checked with TLC 1.8.0.

## The state machine the code keeps implicitly

A round `(asset, startTime)` has no status field. Its state is read off five things:
`up + down`, `openAt`, `closeAt`, `block.timestamp` and `claimed`.

| state | condition | way out |
|---|---|---|
| Empty | `up + down = 0` | `bet` (before `startTime`) |
| Betting | stakes, `now < startTime` | time passes |
| Awaiting open | `now` in `[S, S+D]`, `openAt = 0` | `poke` records open, or the window passes → Void |
| Running | `openAt != 0`, `now < S+300` | time passes |
| Awaiting close | `now` in `[E, E+D]`, `closeAt = 0` | `poke` records close, or the window passes → Void |
| Final | Up / Down / Void | `claim` per bettor (once), `collectFee` (once, Up/Down) |

`poke` records a close even when the open was missed; the round is already Void and stays so.

## Properties and results

Bounds: 2 bettors, stakes {1, 2}, prices {1, 2}, rounds at 2 and 5 (ROUND = 3, D = 1),
fee 3/10 (large on purpose, so rounding shows), time up to 9.

| property | what it says | HIP-3 | Pyth |
|---|---|---|---|
| `Solvent` | the balance covers every payout and fee still owed | holds | holds |
| `WinnerGetsStake` | a winner gets at least their stake back | holds | holds |
| `FinalAfterWindows` | no round is Pending after both windows | holds | holds |
| `VoidOnTime` | a missed checkpoint is Void as soon as its window passes | holds | holds |
| `SharedCheckpoint` | a round's close equals the next round's open | holds (failed before the fix) | holds (failed before the fix) |
| `OutcomeStable` | a final outcome never changes | holds | holds |
| `RecordedFixed` | a recorded price never changes | holds | holds |
| `NoBetAfterStart` | stakes do not move once a round starts | holds | holds |
| `FirstObservation` | each checkpoint gets the first admissible reading | fails | fails |

Current model, `Safety_*.cfg`, all of the above but `FirstObservation`: HIP-3 5,945,066 distinct
states (1 min 7 s), Pyth 13,821,118 (2 min 30 s), no violation. Before the fix (without
`VoidOnTime` and `SharedCheckpoint`): HIP-3 20,712,426, Pyth 38,987,710, no violation.

`FirstObservation` fails as `docs/spec.md` already says: on HIP-3 the poker picks the block
inside the window; on Pyth a later push can land before anyone pokes.

`SharedCheckpoint` was the one finding the spec did not cover. Round T's close and round T+300's
open are the same moment, but each was recorded by its own `poke`, so they could differ (close
101, next open 99). `poke` now records the checkpoint in both rounds (`_record`);
`test/TlaSharedCheckpoint.t.sol` covers either round being poked first and an empty neighbour.

## Does the model catch bugs? (seeded into a copy of the pre-fix model, one round, time up to 7)

| mutant | caught by |
|---|---|
| `poke` re-records the open | `RecordedFixed` |
| payout ignores the fee | `Solvent` |
| bets taken at `startTime` | `NoBetAfterStart` |
| a missed open voids only after the close window | `VoidOnTime` (missed before that property was added) |
| `claim` without its `claimed` check | not caught: `payout` already returns 0 after a claim, so the check is a second guard |

## Run

```sh
java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto -deadlock -config Safety_hip3.cfg FiveMin.tla
```

`Intent_*.cfg` hold `FirstObservation`, which is expected to fail.
Pause is modelled (`SetPaused`) but left out of `Next`: it only gates `bet`.
