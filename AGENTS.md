# Repository Guidelines

## Project Structure & Module Organization

Eta is a small OCaml 5 library built with Dune. Core public code lives in
`lib/eta/`; each exported module has a paired implementation and interface,
for example `effect.ml` and `effect.mli`. The core modules are `Effect`,
`Runtime`, `Cause`, `Exit`, `Duration`, `Schedule`, `Resource`,
`Capabilities`, and `Tracer`. Supporting core modules include `Syntax`,
`Supervisor`, `Channel`, `Queue`, `Pubsub`, `Pool`, `Semaphore`, `Sampler`,
`Logger`, `Meter`, `Log_level`, `Mutable_ref`, `Random`, and `Trace_context`.
Optional public surfaces live in sibling `lib/<feature>/` directories and
publish underscore-named packages/libraries such as `eta_http`, `eta_sql`,
`eta_ai`, and `eta_test`.

Tests live under top-level `test/`, mirroring the `lib/` package layout.
Research work happens under `.scratch/`. Durable research bundles that must be
preserved in git live under tracked `.scratch/research/`; local throwaway
checkouts, build output, generated logs, and work-in-progress probes stay in
ignored `.scratch/` paths outside `.scratch/research/`. Keep `.scratch/` out of
the main Dune workspace and out of the published library.

`docs/` is for durable project and package documentation, not research bundles.
Documentation may summarize a research decision, but it must not depend on
ignored local artifacts. If a research result becomes durable documentation,
write the decision or API rationale as documentation and cite only tracked
provenance, such as `.scratch/research/` material or project tests. If a proof
needs to become an ongoing project gate, promote it into tracked tests,
benchmarks, tools, or source fixtures under `lib/`, `test/`, `bench/`, `tools/`,
or `http-testsuite/`. Otherwise keep the whole research bundle - code, notes,
evidence, logs, and journal - under `.scratch/research/`.

If scratch code needs Dune, make `.scratch/` a separate Dune project and build
specific experiments explicitly, for example `dune build --root .scratch
path/to/target.exe`. Do not treat `dune build --root .scratch` as a freshness
gate for every historical experiment. Generated artifacts belong in `_build/`
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
documented instead of pretending it is optional. `Eta.Par` lives in the
optional `eta_par` package; the root `eta` package contains only the effect
description and interpretation core.

Least astonishment rule: the opam package name, Dune public library name, and
OCaml top-level module should line up. Prefer `eta_sql` -> `Eta_sql`,
`eta_http` -> `Eta_http`, and so on. Do not introduce dotted public library
names such as `eta.sql` for new Eta packages.

## Reference Code

Use local `.reference/` checkouts before inventing patterns from scratch, but
first verify the checkout exists because `.reference/` is ignored by git and is
local workstation state. Treat reference code as prior art, not as a dependency,
and preserve Eta's boundary: applications own state; Eta owns effect description
and interpretation.

- [.reference/zio](/home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio) -
  ZIO reference for typed failures, causes, exits, schedules, scoped resources,
  structured concurrency, streams, metrics, and runtime behavior that Eta
  intentionally echoes. Use it as behavior and test-case prior art; do not copy
  Scala architecture wholesale.

## Build, Test, and Development Commands

Enter the Nix shell and create the OxCaml 5.2.0+ox switch once:

```sh
nix develop
eta-oxcaml-init
```

Build and test gates:

```sh
nix develop -c dune build @install         # all installable packages
nix develop -c dune runtest --force        # full test suite
nix develop -c eta-oxcaml-test-shipped     # shipped-package subset gate
nix develop .#mainline -c eta-mainline-test-shipped # full upstream OCaml 5.4 gate
nix develop .#ocaml54 -c eta-ocaml54-test-erg # Erg's native OCaml 5.4 dependency gate
```

Agents must run repository verification through the Nix flake, not through the
ambient system OCaml or opam switch. Use `nix develop -c ...` for the OxCaml
gate, `nix develop .#mainline -c ...` for the full upstream OCaml 5.4 and
js_of_ocaml gate, and `nix develop .#ocaml54 -c ...` for Erg's focused native
dependency gate.
Ambient/system opam results are not valid handoff evidence unless the user
explicitly asks for a non-Nix reproduction.

OxCaml and upstream OCaml 5.4 are separate build tracks. The `mainline` track
builds every installable package and runs the full native and js_of_ocaml test
surface on OCaml 5.4. The smaller `ocaml54` track covers the Eta packages
consumed natively by Erg, including the Eio HTTP/TLS transport and OpenRouter.
The OxCaml `5.2.0+ox`
switch cannot build or run js_of_ocaml libraries/tests, and the existing JS
stanzas are disabled under that compiler with `enabled_if`. Native Nix/OxCaml
gates therefore do not verify `eta_jsoo`, `eta_js`, `eta_js_stream`,
`eta_http_js`, `eta_js_test`, or their JS tests. When changing js_of_ocaml
code, use the flake's mainline shell and run the relevant JS targets there; do
not report OxCaml gate success as JS adapter verification.

```sh
nix develop .#mainline -c dune runtest test/http_js --force
```

Without Nix, use an OCaml 5.2.0+ox switch, install dependencies, then run the
same Dune targets:

```sh
opam install . --deps-only --with-test
dune build @install
dune runtest --force
```

HTTP-specific suites live under `http-testsuite/`:

```sh
dune build @interop
dune build @cve-regress
dune build @h2spec
dune build @http-bench
dune build @server-load
dune build @red-probes
```

Benchmarks are opt-in repo infrastructure under `bench/`:

```sh
nix develop -c bash bench/run.sh --quick
nix develop -c bash bench/run.sh
nix develop -c dune build @bench
```

`dune runtest` does not run benchmarks.

The core `eta` package requires OCaml `5.2.0+ox` and Dune. Optional packages
declare their own dependencies; for example `eta_eio` adds Eio and `cstruct`,
`eta_sql` declares SQLite, and `eta_http` declares HTTP protocol libraries.
`eta_par` is an optional native-parallelism package, not part of the root
`eta` package.

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

The HTTP interop, adversarial, conformance, and benchmark suite lives under
`http-testsuite/` and is reachable via `dune build @interop`,
`dune build @cve-regress`, `dune build @h2spec`, `dune build @http-bench`,
`dune build @server-load`, and `dune build @red-probes`.

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

Work is done only when it is committed. It is the agent's job to keep the
worktree, branch, and handoff claims in sync before reporting completion.
