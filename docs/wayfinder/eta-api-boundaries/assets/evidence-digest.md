# Handoff: Wayfinding Eta's missing boundary & ergonomics APIs

## What the next session is for

Run the **wayfinder** skill in the Eta repo (`/home/ribelo/projects/ribelo/ocaml/Eta`)
to chart a map whose destination is a **decision set** (spec/ADR-level), not an
implementation: which missing boundary and ergonomics abstractions Eta should
ship, in which packages, with which shapes — and which should be deliberately
ruled out of scope.

A full evidence survey has already been done (this conversation). Do not redo
the survey; use the digest below as the charting input. The survey covered Eta
itself plus six consumer projects. Expected map location:
`docs/wayfinder/eta-api-boundaries/` (name is a suggestion; a sibling effort
`docs/wayfinder/eta-component-runtime/` already exists and shows the format in
use in this repo).

Suggested destination wording to grill from:

> A decided, per-package list of boundary/ergonomics APIs Eta will add, change,
> or explicitly reject — each with a named shape sketch, its package home, its
> interaction with the H-W4 wrapping policy, and its testing/law-registry
> obligations.

## Hard constraints the map must respect (from Eta AGENTS.md)

- Repo: `/home/ribelo/projects/ribelo/ocaml/Eta`. Verify with
  `nix develop -c dune build @install`; never ambient opam.
- **H-W4 Eio-wrapping policy** (AGENTS.md): wrap an Eio primitive only when
  naked Eio would force callers to reimplement an Eta-owned protocol or
  invariant; otherwise expose Eio directly or document a recipe. Many survey
  findings are "missing convenience wrappers" — each candidate must be checked
  against H-W4. This tension is likely the first grilling thread.
- **Package boundary policy**: root `eta` stays minimal; optional capabilities
  publish their own `eta_<feature>` package with their own deps. Each candidate
  API needs a package home decision.
- **Law registry**: any new law-bearing `.mli` prose requires a named
  executable test and a row in `.scratch/research/dx/e22/review/LAWS.md` in the
  same change. The map's tickets should decide claims, not sneak them in.
- Engineering rules: no fallback logic, no compatibility shims, delete old
  paths, break loudly.
- Existing API style guidance: `docs/api-dx.md` (1090 lines — itself evidence
  of vocabulary sprawl; a candidate finding is "too many near-duplicate
  lifters").

## Evidence digest (already gathered; verify by spot-check, don't redo)

Six consumer projects were audited. Recurring, independently-reinvented gaps:

### A. Runtime boundary doors (strongest signal)

Every project hand-writes "run an effect to a result/exit":

- pie: `packages/pie/bin/pie.ml:24-56` (~45 lines: Eio_main + Switch +
  `Eta_eio.Runtime.create` + `Cause.pp` + `is_interrupt_only` + exit codes) and
  ~15 copies in `packages/pie/test/test_pie.ml`.
- nema: `run_io_effect` (`bin/nema/main.ml:27-40`), three runtimes in one
  switch (`bin/nema/main.ml:385-435`), and `run_io` creating a **fresh runtime
  per call**; service layer calls it dozens of times per request
  (`lib/nema/service.ml` — `runtime.effects.run_io` everywhere).
- taumel (js_of_ocaml): fresh `Eta_jsoo.Runtime.create ()` per JS promise door
  (`bin/eta_host_doors.ml:70-80`, `bin/footer_runtime.ml:69-71`); Eta's own
  top-level `Eta_jsoo.run` (`lib/jsoo/eta_jsoo.mli:64-68`) models
  runtime-per-call.
- inn: `run_store_effect` fresh runtime per store call inside the server
  (`lib/server.ml:922-927`); CLI re-runs a whole runtime per HTTP query
  (`bin/main.ml:135-152`).
- exergy (the counterexample): one runtime per session via
  `with_effect_host` (`lib/facade_core/exergy_runtime.ml:72-104`) — ~50 lines
  of correct setup nobody else replicated.

Tension to resolve: `Effect.fresh` is unique only per runtime
(`lib/eta/effect.mli:503-512`), so runtime-per-call silently resets
identities. Either Eta endorses the idiom (document cost/semantics) or ships
the shared-runtime story exergy had to build.

Related: `Exit.to_result` returns `option`; on `None` consumers do
`failwith "effect failed"` and lose the cause (nema, 4 sites). `run_exn`
exists but erases typing. Missing: a run-to-result that preserves cause on
non-typed exits, and/or a documented pattern.

### B. eta_test adoption: zero

`eta_test` (`lib/test/eta_test.mli`) is used by **none** of the six projects.
Structural cause: `Run.run` / `with_test_clock` give no access to real
`env`/`sw`/net, so any test needing real I/O can't use it (pie's socket
tests, nema's LadybugDB tests, inn's server tests). Consumers re-implement
`run_ok`/`run_eta_effect` instead (e.g.
`exergy/lib/test_support/exergy_test_support.ml:16-26`).

### C. HTTP client ergonomics

Three projects independently wrote the same "simple request" wrapper
(client make → `Request.make` → `Header.unsafe_of_list` → `Client.request` →
2xx check → `Body.Stream.read_all` → error mapping): nema
`bin/nema/main.ml:98-136` (~50 lines), taumel
`bin/usage_bridge.ml:242-267`, exergy `lib/provider_wire/`.

`Eta_http.Url` is parse-only (`lib/http/core/url.mli` — no builder, no query
API): taumel hand-rolled encoding via JS `encodeURIComponent`
(`bin/exa_bridge.ml:27-42`); exergy created a whole package
`exergy-provider-wire` whose synopsis is literally "URL encoding and joining"
(`lib/provider_wire/provider_wire.ml:1-38`: `encode_component`, `join_url`,
`with_query`).

Error classification: `Eta_http.Error.kind` has ~25 variants with no coarse
category. nema wrote a 25-case mapper (`bin/nema/main.ml:76-96`); inn resorted
to **substring-grepping the rendered cause text** for `"Connect_error"`
(`inn/bin/main.ml:151-161`) — the worst observed outcome.

### D. Observability bootstrap

`Eta_otel.create` needs runtime_factory + http_client + clock + host/port +
…; there is no env-driven one-call init. pie and grip contain near-identical
~120-line copy-pasted OTLP thread bootstraps (`pie/packages/pie/observability.ml`,
`grip/lib/observability.ml`); exergy wrote its own
(`lib/facade_core/exergy_otel.ml`).

`Eta_observability.annotate` takes one key/value per call; consumers fold it
themselves (`exergy/lib/provider_wire/provider_wire.ml` `Observability.annotate`).
`annotate_all` exists (`lib/observability/eta_observability.mli:71`) but is
under-discovered.

Spans around synchronous work: nema wraps sync code in an effect on a
separate "maintenance runtime" to get spans (`bin/nema/main.ml:403-419`).

### E. eta_component gaps (from the pie survey)

- `Replacement.target` requires `expected_target: Target_revision.t` while
  `Diagnostics.target_revision` returns `option` → pie used `Obj.magic ()`
  (`pie/packages/pie/assistant/service.ml:816`).
- No `pp` for `Context.admission_error` (15 variants) → pie wrote its own
  printer (`service.ml:8-26`). No `pp`/string for `Diagnostics.phase`,
  `integrity`, `lifecycle`, `progress`, `Fence.outcome`/`kind` → hand-written
  converters (`service.ml:35-90`).
- `Entry_id.to_string` exists in the `.ml` (`lib/component/component_entry_id.ml:29`)
  but is hidden by `eta_component.mli:198-205`; pie uses
  `Format.asprintf "%a" Entry_id.pp` as a Hashtbl key
  (`pie/.../assistant/supervision.ml:28-40`). No `Map`/`Set`.
- `Activation.own` ceremony for no-release components
  (`pie/.../rpc_server.ml:15-21`); fence two-step everywhere (a
  `reconcile_and_await` convenience is absent); diagnostics-as-stream is a
  hand-rolled poll loop (`service.ml:737-761`).
- Loader specs exist but unimplemented:
  `docs/issues/eta-component-runtime/02-eta-component-loader.md`,
  `03-eta-component-loader-native.md` (status `ready-for-agent`); they address
  source→admission orchestration, **not** declaration ergonomics.

### F. Effect-core friction

- `Effect.sync` + raise → `Cause.Die` is the most repeated user mistake
  (pie `REVIEW.md` R1a–R1d: four sites with fictional typed error rows).
  `sync_result`/`sync_option` exist and are documented, yet the trap recurs.
  Candidate: explicit exn→typed bridge (`sync_exn ~catch`) or ppx lint.
- `Effect.to_option`/`to_result` under-discovered: pie hand-rolls
  `fold ~ok:(Some) ~error:(fun _ -> None)` ~12 times; combined
  `to_option`/`to_result` use in pie: 1.
- Two-monad supervisor (`Supervisor.Scope` with own `let*` + `Scope.lift`):
  pie used it 0 times, preferring `with_background`/`par`.
- Typed-error glue: many micro-domains `[ `X_error of string ]` with manual
  `map_error` translators at every boundary (pie ~15 sites; nema/exergy
  similar). Probably inherent, but a recipe/helper decision is open.
- Vocabulary sprawl: `docs/api-dx.md` needs 1090 lines to teach the lifter
  selection (`from_result`/`flatten_result`/`sync_result`, `to_result`/
  `to_option`/`to_exit`, `when_`/`when_effect`/`unless`/`unless_effect`, …).

### G. JS boundary (taumel)

- `Eta_jsoo.Runtime.run_exn` renders typed failures as `<typed failure>`
  (documented wart, `lib/jsoo/eta_jsoo.mli:41-45`).
- `Effect.async` canceler contract is subtle; correct usage exists
  (`taumel/bin/node_child_process_eta.ml`, `await_abort_signal`) but was
  clearly expensive to get right.

### What already works (do not "fix" these)

- `Effect.sync_result |> Effect.named` style is adopted cleanly by nema.
- `Schedule.start`/`next` as a pure delay calculator for durable retry loops
  (nema `lib/nema/embedding_retry.ml`).
- Leaf packages as plain OCaml libraries (grip uses `eta_linux_input`
  Result-API without touching `Effect.t`).
- jsoo core (`Effect.race` + `Promise` + AbortSignal doors) works well.

## Suggested charting input (seed fog / first tickets — to be decided by the
grilling, not assumed)

Likely first grilling threads:

1. **Runtime doors**: `run_main` for CLIs? shared-runtime helper
   (`with_runtime`)? stance on runtime-per-call? run-to-result that keeps the
   cause?
2. **HTTP**: does `Client.fetch_string` / `Url.with_query` /
   `Error.category` belong in `eta_http`, or is that app code per H-W4?
3. **eta_test real-I/O story** (env access), or is `eta_test` deliberately
   deterministic-only (then document the recipe and stop pretending it serves
   these tests)?
4. **eta_component surface completions** (`pp`s, `to_string`, target-revision
   hole, `reconcile_and_await`) — small, probably straight to tickets.
5. **OTel init + annotate sugar** package home (`eta_otel` vs a new
   `eta_otel_env`?).
6. **sync→typed bridge** and vocabulary pruning (deprecate/delete vs document —
   note Eta's "delete old paths" rule).
7. **jsoo `run_exn ~pp_err`** and the runtime-per-call question on JS hosts.

Out-of-scope candidates to state explicitly: implementing the component
loader (already specced), redesigning `Effect` core semantics, app-specific
helpers.

## Suggested skills

- **wayfinder** — the frame: chart `docs/wayfinder/eta-api-boundaries/` then
  work tickets one per session.
- **grilling** — destination naming and breadth-first frontier pass; the H-W4
  tension (wrap vs recipe) is a grilling topic, not a research one.
- **domain-modeling** — pin the vocabulary ("boundary door", "runtime door",
  "classification") before tickets sprawl.
- **codebase-design** — deep-module vocabulary for judging whether a proposed
  helper is a shallow wrapper or owns an invariant (feeds the H-W4 test).
- **simple-english** — map and ticket prose per the wayfinder skill.
- **research** (AFK tickets) — e.g. how ZIO (`.reference/zio` checkout) shapes
  its runtime entry points and error rendering, if a ticket wants prior art.
- **prototype** (HITL) — cheap `.mli` sketches of candidate APIs to react to.

## Practical notes for the fresh session

- Consumer project roots for spot-checks:
  `/home/ribelo/projects/ribelo/pie`, `/home/ribelo/projects/ribelo/nema`,
  `/home/ribelo/projects/ribelo/taumel` (jsoo), `/home/ribelo/projects/ribelo/inn`,
  `/home/ribelo/projects/ribelo/grip`, `/home/ribelo/projects/exergy`.
- The Eta repo's existing wayfinder effort lives at
  `docs/wayfinder/eta-component-runtime/`; its `assets/integrated-handoff.md`
  shows the normative-interface style this repo expects.
- Do not treat "consumers hand-roll it" alone as proof an API belongs in Eta —
  each candidate must pass H-W4 and the package-boundary policy; some answers
  will be "documented recipe, not code", and ruling things out is a legitimate
  outcome of the map.
