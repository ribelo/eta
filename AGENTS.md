# Repository Guidelines

## Project Structure & Module Organization

Eta is a small OCaml 5 library built with Dune. Core public code lives in
`lib/eta/`; each exported module has a paired implementation and interface,
for example `effect.ml` and `effect.mli`. The core modules are `Effect`,
`Runtime`, `Cause`, `Exit`, `Duration`, `Schedule`, `Resource`,
`Capabilities`, and `Tracer`. Optional public surfaces live in sibling
`lib/<feature>/` directories and publish underscore-named packages/libraries
such as `eta_http`, `eta_sql`, `eta_ai`, and `eta_test`.

Tests live under top-level `test/`, mirroring the `lib/` package layout. Research
experiments live under `.scratch/`; keep them out of Dune discovery and out of
the published library unless they are deliberately promoted into real project
code under `lib/`, `test/`, or `tools/`. Generated artifacts belong in `_build/`
and local switches in `_opam/`.

Optional external-engine integrations live under `drivers/`. Driver packages may
depend on Eta, but Eta core libraries under `lib/` must not depend on drivers.

## Package Boundary Policy

Eta follows an **install only what you use** principle. The root `eta` package
must contain only the core runtime and dependencies needed by ordinary Eta
programs. Optional capabilities must publish their own obvious
`eta_<feature>` package and public library, and must carry their own external
dependencies there.

Examples:

- SQLite code belongs in `eta_sql`, along with `conf-sqlite3`.
- HTTP code belongs in `eta_http` and sibling HTTP packages such as
  `eta_http_h2`, along with `faraday`, `angstrom`, `decompress`, and related
  network dependencies.
- AI providers belong in `eta_ai` or `eta_ai_<provider>`, along with provider
  codecs and JSON dependencies.
- Test helpers belong in `eta_test` or `eta_schema_test`, along with
  `alcotest` and `eio_main`.
- PPX code belongs in `ppx_eta`, along with `ppxlib`.

Do not add optional, provider-specific, C-stub, system-library, codec, protocol,
or testing dependencies to `eta`. If a feature cannot be separated because the
core runtime genuinely uses it, keep that dependency small, explicit, and
documented instead of pretending it is optional. `Eta.Par` is the current
runtime substrate for core island execution; it lives in the `eta` package
while that relationship remains true.

Least astonishment rule: the opam package name, Dune public library name, and
OCaml top-level module should line up. Prefer `eta_sql` -> `Eta_sql`,
`eta_http` -> `Eta_http`, and so on. Do not introduce dotted public library
names such as `eta.sql` for new Eta packages.

## Reference Code

Use the local `.reference/` directories before inventing patterns from scratch.
Treat them as prior art, not dependencies, and preserve Eta's boundary:
applications own state; Eta owns effect description and interpretation.

- [.reference/effect-smol](/home/ribelo/projects/ribelo/ocaml/Eta/.reference/effect-smol) - Effect v4 reference for behavior Eta intentionally echoes: typed failures, success values, causes, exits, schedules, retry/repeat, scoped resources, concurrency semantics, and combinator naming. Use it especially as a source of behavior and test cases to port into OCaml when Eta partially reimplements the same semantics. Do not copy TypeScript architecture wholesale or import Effect-only concepts that Eta explicitly omits.
- [.reference/oxmono](/home/ribelo/projects/ribelo/ocaml/Eta/.reference/oxmono) - OCaml/OxCaml reference for high-quality library style, Dune/package structure, Alcotest usage, Eio integration, and idiomatic OxCaml. Use it as the local standard for writing good OCaml and OxCaml in this repo, while keeping changes scoped to Eta's small library surface.
- [.reference/riot](/home/ribelo/projects/ribelo/ocaml/Eta/.reference/riot) - Riot is an opinionated OCaml stack (build tool, package manager, actor-model runtime, standard library, web framework, DB drivers, TUI, serialization). Reference for: actor-model concurrency patterns (supervision, message passing, multi-core fibers), property-based testing with `propane`, snapshot and fuzz testing infrastructure, monorepo package layout with `riot.toml` manifests, and idiomatic OCaml library style across a large surface. Use it when Eta needs prior art for structured concurrency, test infrastructure beyond Alcotest, or package/build ergonomics.

## Build, Test, and Development Commands

- `nix develop -c dune build`: build the library using the pinned Nix shell.
- `nix develop -c dune runtest --force`: run the full test suite.
- `opam install . --deps-only --with-test`: install dependencies without Nix.
- `dune build` / `dune runtest --force`: local equivalents when the OCaml
  environment is already configured.

The core `eta` package requires OCaml `5.2.0+ox`, Dune, Eio, `portable`, and
`cstruct`. It also ships `Eta.Par` because the core runtime uses that scheduler
for island execution. Optional packages declare their own dependencies; for
example `eta_sql` declares SQLite and `eta_http` declares HTTP protocol
libraries.

## Coding Style & Naming Conventions

Follow the existing OCaml style: two-space indentation, concise helper names,
and pipelines where they improve readability. Keep public APIs in `.mli` files
and avoid widening exported types accidentally. Use lowercase snake_case for
values, PascalCase for modules, and polymorphic variants such as `` `Timeout``
for typed failures.

There is no repository formatter configuration at the moment. Match nearby code
and run Dune before submitting changes.

## Testing Guidelines

Tests use Alcotest plus Eio runtime helpers. Add focused `let test_* ()`
functions in `test/eta/test_eta.ml`, then register them in the suite in that file.
Prefer deterministic helpers such as the existing test clock for timeouts,
delays, and fiber scheduling. Cover both `Exit.Ok` and `Exit.Error` paths when
changing runtime interpretation or typed failures.

Run `nix develop -c dune runtest --force` before handing off changes.

The HTTP interop, adversarial, and benchmark suite lives under `http-testsuite/` and is reachable via `dune build @interop`, `dune build @cve-regress`, and `dune build @http-bench`.

Benchmarks are opt-in repo infrastructure under `bench/`. Use
`nix develop -c bash bench/run.sh --quick` for a fast performance snapshot,
`nix develop -c bash bench/run.sh` for the full local record, and
`nix develop -c dune build @bench` for runtime-only benchmark executables.
Benchmarks are deliberately not attached to `dune runtest`.

## Engineering Rules

**Churn and friction are not design objections.**
Change volume and migration effort are never valid reasons to keep a stale
code path, introduce a compatibility shim, or avoid the correct fix. The cost
of maintaining dead or transitional code always exceeds the one-time cost of
updating callers. Do not invoke "churn" or "friction" as arguments.

**No fallback logic, compatibility shims, or silent defaults.**
Every code path serves the current contract. If a signature changes, update all
callers or delete the old signature entirely. Do not add runtime branches to
support old callers.

**Delete old paths instead of deprecating them.**
When a behavior changes, remove the old behavior. Eta does not carry migration
paths within the library. The changelog and commit history are the migration
guide for consumers.

**Break loudly and clearly.**
When a precondition is violated or state is invalid, raise an error or return
an `` `Error`` exit immediately. Prefer compile-time rejection via types where
possible; at runtime, fail clearly rather than no-op, default, or skip.

## Eio Wrapping Policy

H-W4: Wrap an Eio primitive when naked Eio would force callers to reimplement an Eta-owned protocol or invariant: typed failure preservation, cancellation cleanup, scoped lifecycle, close fences, backpressure ownership, mode/portability fences, or runtime observability. Otherwise expose Eio directly via a `from_eio_X` bridge or document the recipe.

The rule predicts the current surface: `Pool`, `Channel`, `Resource`, `Mailbox`, and `Effect.timeout_as` wrap; `Eio.Mutex`, `Eio.Condition`, `Eio.Path`, and `Eio.Buf_read` stay direct; `Stream.from_eio_stream` is a bridge with an explicit semantic gap.

Evidence sources: V-Realtime-Substrate, V-Channel-Choice, V-Pool-Survival, and V-Rs.

## Commit & Pull Request Guidelines

The short history uses conventional-style commits such as `feat: par / all /
for_each_par concurrent combinators`. Keep commit subjects imperative,
specific, and scoped to the change.

Pull requests should describe the behavior change, mention affected modules,
link any relevant issue, and include the exact test command run. For API
changes, call out updates to both `.ml` and `.mli` files.

## Agent-Specific Instructions

Do not treat Eta as an application framework. The README is explicit:
applications own state; Eta owns effect description and interpretation.
Preserve that boundary when adding features.
