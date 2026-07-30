# Follow-up 1: DX-E44 — rework after independent review (4 verified findings)

Your delivery was reviewed PR-style by the independent oracle. Verdict:
promote-with-reservations — but two of the four findings are contract
integrity issues the wave exists to catch, so we fix before merge. All four
were independently verified by the orchestrator against the cited lines.
Everything in `objective.md` still applies; this file overrides where noted.

## F1 — batch metrics: allocation regression + unestablished bound

The split's batch path allocates twice per point where the old code
allocated once: `lib/observability/eta_observability.ml` `point_of_metric`
copies each descriptor into a `Capabilities.metric_point` with `ts_ms = 0`,
then `lib/eta/spi.ml` `record_metric_point` copies AGAIN via
`{ point with ts_ms }`. Pre-split (`effect_observability.ml` at fd27e518),
batching built only the timestamped point.

Worse, the watchlist workload exercises only single `metric_update` — the
regressed path (`metric_updates`, `metric_updates_lazy`, interception) is
unmeasured, and LAWS.md CD-E22-013 already flags it as debt. The
"all changed paths < 2%, allocations equal or lower" claim is currently
not established for the batch path.

Required:
- Eliminate the double allocation. Suggested shape (yours to adjust): make
  the lazy producer timestamp-aware —
  `make_points : ts_ms:int -> Capabilities.metric_point list` — so `spi.ml`
  computes `ts_ms` once and each point is constructed exactly once, with a
  uniform batch timestamp. No second copy anywhere.
- Extend the watchlist workload with `metric_updates` and
  `metric_updates_lazy` (and an interception case if cheap), re-run the
  15-pair alternating protocol, and report the batch path explicitly.
- Fix the report language: replace "every changed-path wall regression is
  below 2%" with an honest uncertainty statement (pooled deltas AND
  per-pair spread; no one-sided bound claimed from 15 pairs).

## F2 — `local_with_binding` restoration contract unspecified

`lib/eta/runtime_contract.mli` exports `local_with_binding` with zero
prose. The SDK's restoration promises delegate to it; the supplied backends
(Eio scoped bindings, jsoo `Fun.protect`) are correct — but a third-party
backend could satisfy `RUNTIME` while violating the SDK's documented
promises.

Required: document in `runtime_contract.mli` that `local_with_binding`
must restore the previous binding on normal return, on exception, and on
cancellation; that nested bindings are LIFO; and the fork-inheritance rule
(children inherit at fork, no join-merge) — then register these as backend
conformance requirements (law registry row citing the Eio/jsoo
implementations as the reference evidence).

## F3 — three SDK prose qualifications

1. `with_result_attrs` (`eta_observability.mli:96-101`): require total
   callbacks; state the failure behavior — raising `ok_attrs` replaces
   success with a defect; raising `err_attrs` adds a suppressed finalizer
   defect.
2. `with_context` (`:131-136`): add the qualifier — the installed context
   parents the next span *when no active in-process parent exists* (active
   parent takes precedence per `runtime_instrument.ml`).
3. `is_tracing_enabled` (`:82-84`): it reports *effective admission*, not
   "installed" — it is false under `suppress_observability` even with a
   tracer installed. Fix the prose to say so.

## F4 — CHANGELOG missing the covariance exposure

`type ('a, +'err) t` is now public in `lib/eta/effect.mli:23` — a real
type-inference change for consumers. Add it to
`.scratch/research/dx/e44/CHANGELOG.md` with the one-line justification
(separately compiled polymorphic SDK constants).

## Then

- Update `report.md` (gates, bench section, deviations) and append a
  journal addendum — do not edit sealed sections.
- Re-run the native trio; mainline JS only if OCaml sources in the JS
  closure changed (they likely did — metric/binding code).
- The **reviewer of record** (the same oracle) re-reviews the rework.
- End signal unchanged: `E44 READY FOR REVIEW` with a summary of each
  finding's resolution.
