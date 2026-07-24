# Follow-up 4: DX-E15 — first-cancellation-wins race + teardown honesty

Round four. The both-context relay works in both directions, but one
HIGH and one LOW remain.

## 1. HIGH: the first cancellation source does not necessarily win

The relay forwards descendant cancellation ASYNCHRONOUSLY (a daemon).
Race: descendant `S` cancelled at t1; parent `C` cancelled at t2
(t1 < t2); `C` cancels `R` directly before the relay daemon is
scheduled; the relay's later cancel of already-cancelled `R` loses.
Reviewer reproduced: descendant first, parent second → observed
`parent`, contradicting the mli's "the first cancellation wins"
(`lib/eta/effect.mli:248-249`). This matters for code that
distinguishes cancellation REASONS (e.g. timeout vs. ordinary parent
cancellation).

**Resolve with evidence, two acceptable outcomes:**

(a) **Synchronous forwarding, if Eio's internals offer it.** If the
hidden `Eio__core__Cancel` machinery lets you register a cancellation
FUNCTION (not a daemon fiber) on the relay context — one that runs
synchronously during `Cancel.cancel`'s tree walk — use it: S-cancel
then cancels `R` synchronously, and first-cancelled-first-wins holds up
to `cancel`-call ordering. Document THAT granularity ("when sources
compete, the winner is the first cancellation call executed").
(b) **If no synchronous hook exists**, weaken the mli contract to the
honest one: delivery at most once; when cancellation sources compete,
the winner is scheduler-determined; the observable is a single
interruption cause. Do not promise ordering no implementation can keep.

Either way: the competing-sources test must use DISTINGUISHABLE reasons
(the current test's both-`Exit` sources can't detect the mis-ordering)
and assert whichever contract (a) or (b) you land.

## 2. LOW: teardown honesty + per-restore cost

- After `active := false`, `Eio.Switch.run` cancels and joins the relay
  daemon — a suspension after the successful-exit check. The report's
  "no suspension before restoring protected state" claim is now
  imprecise; correct it (the race window itself is sound: no suspension
  between the body's check and `active := false`).
- Per-restore cost is now: one relay switch + one daemon fiber + one
  shutdown scheduling cycle. Acknowledge it in the report; if
  `interruptible` is plausible in hot loops (the accept-loop victim IS
  a loop), add a watchlist/bench note or a quick measurement
  (restorations/sec) so the cost is a number, not a shrug.

## Records and gates

Journal: append-only — the async-relay ordering race and the (a)/(b)
resolution with its evidence. Report + mli: the contract text matching
the landed outcome. Gates: full set both shells
(`_build-mainline` for mainline).

## Done means

`E15 READY FOR REVIEW` / `E15 BLOCKED: <reason>` / `E15 STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
