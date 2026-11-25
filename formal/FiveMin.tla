---------------------------- MODULE FiveMin ----------------------------
(* A model of src/FiveMin.sol: rounds, bets, poke, outcome, claim, fee.
   Time is whole blocks. The price source is either HIP-3 (the reading's
   time is the block's; the oracle may change every block) or Pyth push
   (a stored reading; anyone may push a newer signed update whose publish
   time is not ahead of the block). Token transfers move exactly the
   amount (the contract refuses any token that does not). *)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS Users, Amounts, Prices, Starts, ROUND, D, FEE, DEN, TMAX,
          SOURCE, MAXBETS

CP == Starts \cup {s + ROUND : s \in Starts}   \* checkpoints
Sides == {"up", "down"}

VARIABLES now, src, firstObs, paused, rnd, stake, nbets, claimed, bal, out

vars == <<now, src, firstObs, paused, rnd, stake, nbets, claimed, bal, out>>

\* What source.read returns in the current block.
Read == IF SOURCE = "hip3" THEN [px |-> src.px, at |-> now] ELSE src

\* FiveMin._admissible
Adm(at, t, blk) == blk >= t /\ blk <= t + D /\ at >= t /\ at <= t + D /\ at <= blk

\* The first reading that was admissible for each checkpoint, whether or not
\* anyone poked then. Not contract state: the spec's "first observation".
ObsAfter(rd, blk) ==
  [t \in CP |-> IF firstObs[t] # 0 THEN firstObs[t]
                ELSE IF Adm(rd.at, t, blk) THEN rd.px ELSE 0]

Init ==
  /\ now = 0
  /\ src \in [px : Prices, at : {0}]
  /\ firstObs = [t \in CP |-> 0]
  /\ paused = FALSE
  /\ rnd = [s \in Starts |-> [up |-> 0, down |-> 0, openPx |-> 0, closePx |-> 0,
                              openAt |-> 0, closeAt |-> 0, feeCollected |-> FALSE]]
  /\ stake = [s \in Starts |-> [u \in Users |-> [up |-> 0, down |-> 0]]]
  /\ nbets = [s \in Starts |-> [u \in Users |-> 0]]
  /\ claimed = [s \in Starts |-> [u \in Users |-> FALSE]]
  /\ bal = 0
  /\ out = 0

----------------------------------------------------------------------------
\* views

Outcome(s) ==
  LET r == rnd[s] IN
  IF r.openAt = 0 THEN (IF now > s + D THEN "Void" ELSE "Pending")
  ELSE IF r.closeAt = 0 THEN (IF now > s + ROUND + D THEN "Void" ELSE "Pending")
  ELSE IF r.up = 0 \/ r.down = 0 \/ r.closePx = r.openPx THEN "Void"
  ELSE IF r.closePx > r.openPx THEN "Up" ELSE "Down"

Losers(s)  == IF Outcome(s) = "Up" THEN rnd[s].down ELSE rnd[s].up
Winners(s) == IF Outcome(s) = "Up" THEN rnd[s].up ELSE rnd[s].down
FeeOf(s)   == (Losers(s) * FEE) \div DEN

Payout(s, u) ==
  IF claimed[s][u] THEN 0 ELSE
  LET o == Outcome(s) st == stake[s][u] IN
  IF o = "Pending" THEN 0
  ELSE IF o = "Void" THEN st.up + st.down
  ELSE LET mine == IF o = "Up" THEN st.up ELSE st.down
           pot  == Losers(s) - FeeOf(s)
       IN IF mine = 0 THEN 0 ELSE mine + (mine * pot) \div Winners(s)

FeeOwed(s) ==
  IF rnd[s].feeCollected \/ Outcome(s) \in {"Pending", "Void"} THEN 0 ELSE FeeOf(s)

RECURSIVE SumUsers(_, _)
SumUsers(s, U) == IF U = {} THEN 0 ELSE LET u == CHOOSE u \in U : TRUE
                                       IN Payout(s, u) + SumUsers(s, U \ {u})
RECURSIVE SumRounds(_)
SumRounds(S) == IF S = {} THEN 0 ELSE LET s == CHOOSE s \in S : TRUE
                                      IN FeeOwed(s) + SumUsers(s, Users) + SumRounds(S \ {s})

Owed == SumRounds(Starts)

----------------------------------------------------------------------------
\* actions

Tick ==
  /\ now < TMAX
  /\ now' = now + 1
  /\ IF SOURCE = "hip3"
       THEN \E p \in Prices :
              /\ src' = [px |-> p, at |-> 0]
              /\ firstObs' = ObsAfter([px |-> p, at |-> now + 1], now + 1)
       ELSE /\ src' = src
            /\ firstObs' = ObsAfter(src, now + 1)
  /\ UNCHANGED <<paused, rnd, stake, nbets, claimed, bal, out>>

\* Pyth: a push (sponsored or anyone's signed update) newer than the stored one.
Push(p, t) ==
  /\ SOURCE = "pyth"
  /\ t > src.at /\ t <= now
  /\ src' = [px |-> p, at |-> t]
  /\ firstObs' = ObsAfter(src', now)
  /\ UNCHANGED <<now, paused, rnd, stake, nbets, claimed, bal, out>>

SetPaused(b) ==
  /\ paused' = b
  /\ UNCHANGED <<now, src, firstObs, rnd, stake, nbets, claimed, bal, out>>

Bet(s, u, side, amt) ==
  /\ ~paused
  /\ now < s                          \* BETS_OPEN lower bound left out
  /\ nbets[s][u] < MAXBETS
  /\ rnd' = [rnd EXCEPT ![s][side] = @ + amt]
  /\ stake' = [stake EXCEPT ![s][u][side] = @ + amt]
  /\ nbets' = [nbets EXCEPT ![s][u] = @ + 1]
  /\ bal' = bal + amt
  /\ UNCHANGED <<now, src, firstObs, paused, claimed, out>>

Staked(s) == s \in Starts /\ rnd[s].up + rnd[s].down > 0

\* poke records checkpoint t in both rounds that use it (FiveMin._record):
\* the close of the round ending at t and the open of the round starting at t.
Poke(s) ==
  LET rd == Read
      ts == {t \in {s, s + ROUND} : Adm(rd.at, t, now)}
      closes == {e \in Starts : e + ROUND \in ts /\ Staked(e) /\ rnd[e].closeAt = 0}
      opens  == {b \in Starts : b \in ts /\ Staked(b) /\ rnd[b].openAt = 0}
  IN
  /\ Staked(s)
  /\ closes \cup opens # {}            \* otherwise a no-op
  /\ rnd' = [r \in Starts |->
               [rnd[r] EXCEPT
                 !.closePx = IF r \in closes THEN rd.px ELSE @,
                 !.closeAt = IF r \in closes THEN rd.at ELSE @,
                 !.openPx  = IF r \in opens  THEN rd.px ELSE @,
                 !.openAt  = IF r \in opens  THEN rd.at ELSE @]]
  /\ UNCHANGED <<now, src, firstObs, paused, stake, nbets, claimed, bal, out>>

Claim(s, u) ==
  LET amt == Payout(s, u) IN
  /\ ~claimed[s][u]
  /\ amt > 0
  /\ claimed' = [claimed EXCEPT ![s][u] = TRUE]
  /\ bal' = bal - amt
  /\ out' = out + amt
  /\ UNCHANGED <<now, src, firstObs, paused, rnd, stake, nbets>>

CollectFee(s) ==
  /\ Outcome(s) \notin {"Pending", "Void"}
  /\ ~rnd[s].feeCollected
  /\ rnd' = [rnd EXCEPT ![s].feeCollected = TRUE]
  /\ bal' = bal - FeeOf(s)
  /\ out' = out + FeeOf(s)
  /\ UNCHANGED <<now, src, firstObs, paused, stake, nbets, claimed>>

Next ==
  \/ Tick
  \/ \E p \in Prices, t \in 0..TMAX : Push(p, t)
  \* SetPaused only gates Bet; left out of the checked runs to keep the state space small
  \/ \E s \in Starts, u \in Users, side \in Sides, a \in Amounts : Bet(s, u, side, a)
  \/ \E s \in Starts : Poke(s)
  \/ \E s \in Starts, u \in Users : Claim(s, u)
  \/ \E s \in Starts : CollectFee(s)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
\* What the contract and spec promise

\* The pool can always pay everything it owes (spec: payouts never exceed stakes).
Solvent == bal >= 0 /\ bal >= Owed

\* A winner always gets at least their stake back.
WinnerGetsStake ==
  \A s \in Starts, u \in Users :
    (Outcome(s) \in {"Up", "Down"} /\ ~claimed[s][u]) =>
      Payout(s, u) >= (IF Outcome(s) = "Up" THEN stake[s][u].up ELSE stake[s][u].down)

\* Every round is final once both windows have passed.
FinalAfterWindows == \A s \in Starts : now > s + ROUND + D => Outcome(s) # "Pending"

\* Spec: "If either checkpoint has no admissible reading by T + maxDelay: void"
\* (as soon as that window has passed, not later).
VoidOnTime ==
  \A s \in Starts :
    /\ (rnd[s].openAt = 0 /\ now > s + D) => Outcome(s) = "Void"
    /\ (rnd[s].closeAt = 0 /\ now > s + ROUND + D) => Outcome(s) = "Void"

\* A final outcome never changes; a recorded price never changes.
OutcomeStable ==
  [][\A s \in Starts : Outcome(s) # "Pending" => Outcome(s)' = Outcome(s)]_vars
RecordedFixed ==
  [][\A s \in Starts :
       /\ rnd[s].openAt  # 0 => (rnd[s].openPx'  = rnd[s].openPx  /\ rnd[s].openAt'  = rnd[s].openAt)
       /\ rnd[s].closeAt # 0 => (rnd[s].closePx' = rnd[s].closePx /\ rnd[s].closeAt' = rnd[s].closeAt)]_vars

\* No stakes move once a round has started.
NoBetAfterStart ==
  [][\A s \in Starts : now >= s => (rnd[s].up' = rnd[s].up /\ rnd[s].down' = rnd[s].down)]_vars

----------------------------------------------------------------------------
\* The spec's headline wording, checked literally ("each checkpoint takes the
\* first observation recorded at or after it"). Expected to fail where the
\* spec already says the poker picks within the window.
FirstObservation ==
  \A s \in Starts :
    /\ rnd[s].openAt  # 0 => rnd[s].openPx  = firstObs[s]
    /\ rnd[s].closeAt # 0 => rnd[s].closePx = firstObs[s + ROUND]

\* A round's close and the next round's open are the same checkpoint and get
\* the same price (failed before poke recorded both; holds since).
SharedCheckpoint ==
  \A s1, s2 \in Starts :
    (s1 + ROUND = s2 /\ rnd[s1].closeAt # 0 /\ rnd[s2].openAt # 0) =>
      rnd[s1].closePx = rnd[s2].openPx
=============================================================================
