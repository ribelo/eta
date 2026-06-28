# Eta — Code Review Remediation

Status: Closed. All tasks exist in the backlog and are exported to `.backlog/Eta-<id>.md`. Read those for the full description, design notes, RED-test plan (where applicable), and acceptance criteria. This file is the index, not a duplicate of task content.

Epic: **Eta-6j9** — Code review remediation — structural and bug findings.

---

## How to work this objective

1. Pick a task. Read `.backlog/Eta-<id>.md` for the bug, the RED-test plan (if any), the fix shape, and the acceptance criteria.
2. For tasks marked **RED test first**, write the test before the fix. The test must fail on current code and pass after the fix.
3. For tasks marked **no RED test**, the rationale is in the task design field — usually one of: pure rename, public-vs-private API reshape, behavior-preserving refactor (existing test suite is the regression gate), or the test would be flaky (race-condition probabilistic).
4. Run `nix develop -c dune runtest --force` before handoff. Behavior-preserving refactors must show pass/fail parity pre and post.
5. Tasks are not mutually blocked; close in any order. Two coordination notes:
   - `Eta-tkw` (effect.ml/runtime.ml split) and `Eta-jgf` (narrow Effect.Private) share the same private-library boundary — landing them together is cleaner than landing them separately.
   - `Eta-44a` (daemon failure diagnostics) is `related` to `Eta-1lf` (finalizer drain at top level + fork_internal). The orphaned `~finalizers:(ref [])` inside `fork_internal` is fixed by `Eta-1lf`; `Eta-44a` is purely the diagnostic-sink piece.

---

## Tasks — Review 1 (behavioral bugs, RED test first unless noted)

### P0
- `Eta-oj1` — HTTP header CRLF injection

### P1
- `Eta-1lf` — Drain finalizers at every Runtime.run boundary (covers fork_internal too)
- `Eta-asf` — Schedule.and_then must offset step for the second schedule
- `Eta-3k8` — Plumb a clock into Retry-After absolute-date parsing
- `Eta-89b` — Url.authority must restore brackets for IPv6 literals
- `Eta-u1f` — H2 buffer-full surfaces as typed Security_error
- `Eta-9jk` — Cap close-delimited and read_all body sizes
- `Eta-k2y` — Effect.Island uses real indexed batch executor
- `Eta-18b` — Effect.Island worker_die captures message + backtrace

### P2
- `Eta-8wp` — Close TCP flow when TLS upgrade fails
- `Eta-jgf` — Narrow Effect.Private surface (no RED — API reshape)
- `Eta-bl0` — Effect.tap_error preserves typed failure when observer raises
- `Eta-zfn` — retry_eff catch-all uses cause_of_exn_runtime
- `Eta-44a` — Daemon failures surface to a runtime diagnostic sink
- `Eta-913` — In-memory tracer emits valid span_id and trace_id
- `Eta-0m2` — Capabilities.random uses CAS update (no RED — race-test would be flaky)
- `Eta-cpl` — Retry runner honors Retry_with_new_connection or removes the variant
- `Eta-li4` — H1 write_to_flow returns typed errors instead of raising

### P3
- `Eta-onp` — Keep Effect.sync canonical; remove stale old spelling (no RED — pure cleanup)
- `Eta-18v` — Rename or document Effect.collect_names limitation (no RED — naming)

---

## Tasks — Review 2 (structural refactors, no RED)

- `Eta-tkw` — Split effect.ml and runtime.ml into focused modules behind a private boundary
- `Eta-ev7` — Split test_eta.ml and test_eta_http.ml into focused test modules
- `Eta-39o` — Extract shared provider codec helpers across eta-ai-* packages

---

## Out of scope

- Anything not listed above. New findings discovered while doing this work go into the backlog as new tasks (with `discovered-from` edges to the originating task), not folded into existing ones.
- API reshape beyond what each task explicitly authorizes. If a refactor wants to widen or break the public surface, file a separate task and stop.
