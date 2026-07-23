# Follow-up 1: DX-E22 — six findings from independent review

The suite's bones are good (lifecycle matrices, Semaphore cancellation,
`par`/`race` machinery, event-equality design all held under attack), but
the independent review found six findings that must be fixed before this
promotes. The policy's credibility IS the deliverable — fix the substance,
not the optics.

## Finding 1 (Critical): the census must be mli-anchored

The promoted policy says "every law stated in an `.mli` must have a named
qcheck property". The current 22-row census is not that: rows 1–6 register
algebraic laws `effect.mli` does not state in prose; rows 18–19 admit
`schedule.mli` prose absence; meanwhile normative prose that IS in mlis is
deferred (`all`/`all_settled`, all-exit `with_scope`, Channel sender
cancellation, Semaphore brackets). And the five footguns don't exhaust the
uncensused prose (cleanup-failure composition, blocked-sender FIFO, Queue
shutdown, nested override semantics, interceptor Drop/order…).

Fix, all three parts:
(a) Restructure `LAWS.md` into two explicit sections: **mli-stated laws**
    (each row cites the exact normative span, e.g. `effect.mli:494-506`)
    and **model laws** (algebraic/semantic laws the mli doesn't yet state
    in prose — the plan's bootstrap inventory). No hiding: a model law is
    either promoted into mli prose (preferred for the monad/error-channel
    equations — short, real prose) or explicitly marked prose-pending.
(b) Add the missing mli-stated laws with properties: `all`/`all_settled`
    (whatever their mlis actually claim), `with_scope` all-exit release,
    Channel sender-cancellation fence, Semaphore bracket guarantees — and
    sweep the mlis once more for normative prose you missed.
(c) Tighten the AGENTS.md paragraph: define "law-bearing prose" (normative
    behavioral/algebraic claims), require exact `.mli` span citation per
    census row, one row per claim, and the non-vacuity/coverage
    obligations. Close the loophole the reviewer named.

## Finding 2 (High): schedule monotonicity vacuity

`law_properties.ml` (~652–671): `collect` accepts `None` (early `Done`)
returning the prefix; `monotone []`/`monotone [_]` are trivially true — a
regression making schedules terminate immediately passes. Fix: assert
`List.length delays = expected` (exactly the requested number of
`Continue` steps) BEFORE monotonicity, for every generated valid input.

## Finding 3 (Medium): clock restoration must be exact

(~759–781): `after_now <> overridden_now` passes restoration to ANY wrong
value. Capture the outer clock state and assert exact `now_ms`/timestamp
equality (normally time zero; the explicitly driven outer value after the
timeout case). Logger/tracer/random restoration is already stronger —
match it.

## Finding 4 (Medium): restore the empty-census side condition in general equality

(~190–209, 253–307): `sealed` sets `pending_fibers = None`, hiding a
silently leaked fiber on one side. The algebraic generated class has no
legitimate background work, so requiring `Some []` on both outcomes cannot
false-fail. Make the empty census part of the general equivalence.

## Finding 5 (Medium): prove out-of-order completion happened

(~309–344): `par`/`map_par` order properties never establish that a later
input finished first — a serial implementation passes. Force both
completion orders (gates or completion tags/events) and assert at least
one observed case where completion order ≠ input order, then that results
are still input-ordered.

## Finding 6 (Low): report honesty

The generated class has SIX recursive forms (not five), and the algebraic
class contains no defect/owned-cancellation leaves — only the lifecycle
matrices cover all four exit kinds. Correct `report.md` (and LAWS.md if
affected) to say exactly that.

## Records

Journal: new append-only entry covering the findings and your fixes.
Report + LAWS.md + AGENTS.md updated. Red-team: Finding 2's vacuity is now
a documented attack example (show the would-be-passing regression now
fails). The FG-E22-001..005 footguns: re-triage after (a)–(b) — some may
be closed by the census restructuring, the rest stay tracked.

## Gates

Full re-run after fixes (native trio; mainline `test/laws` +
`@install`). The suite must pass with the strengthened assertions.

## Done means

`E22 READY FOR REVIEW` / `E22 BLOCKED: <reason>` / `E22 STOP: <§4.6>`.
Same scope fence. This file stays uncommitted.
