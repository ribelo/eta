# Eta API boundaries map

## Destination

A decided, per-package list of boundary and ergonomics APIs that Eta will
add, change, or explicitly reject. Each entry has a named shape sketch, a
package home, an H-W4 verdict, and its law-registry obligations. The resolved
map itself is the handoff. Decisions live in tickets. This file indexes them.

## Notes

The domain is the Eta public API surface, judged against six consumer
projects: pie, nema, taumel, inn, grip, and exergy. The evidence survey is
complete. The digest lives in
[assets/evidence-digest.md](assets/evidence-digest.md). Spot-check the digest.
Do not redo the survey.

Vocabulary for this effort:

- A **runtime door** runs an `Effect.t` to completion at a host boundary, for
  example a process main, a request loop, or a JS promise. The door renders
  the exit.
- A **boundary API** is an Eta API that crosses between the effect world and
  the host world.
- An **ergonomics API** is an Eta API that shortens a repeated pattern inside
  the effect world.

Constraints from AGENTS.md:

- The H-W4 policy: wrap an Eio primitive only when naked Eio forces callers
  to reimplement an Eta-owned protocol or invariant. Otherwise expose Eio
  directly, or document a recipe.
- The package boundary policy: the root `eta` package stays minimal. Optional
  capabilities publish their own `eta_<feature>` package with their own
  dependencies.
- The law registry: new law-bearing `.mli` prose needs a named executable
  test and a row in `.scratch/research/dx/e22/review/LAWS.md` in the same
  change.
- Engineering rules: no fallback logic, no compatibility shims, delete old
  paths, break loudly.
- Verify with `nix develop -c dune build @install`. Ambient opam results are
  not valid evidence.
- The native OxCaml gates do not build the jsoo packages. A jsoo decision
  names its own verification story.

Consumer project roots for spot-checks:

- `/home/ribelo/projects/ribelo/pie`
- `/home/ribelo/projects/ribelo/nema`
- `/home/ribelo/projects/ribelo/taumel` (jsoo)
- `/home/ribelo/projects/ribelo/inn`
- `/home/ribelo/projects/ribelo/grip`
- `/home/ribelo/projects/exergy`

Use `$grilling` and `$domain-modeling` for decision tickets. Use
`$codebase-design` for the deep-module test in ticket 01. Use `$research`
for research tickets. Use `$prototype` for `.mli` sketches. Use `$eio` and
`$oxcaml` when a ticket touches their ground. Write all map and ticket prose
per `$simple-english`.

This map produces decisions only. Implementation happens after the map, in
ordinary build work.

## Decisions so far

## Not yet specified

- The real-I/O test story if [eta_test scope and real I/O](issues/05-eta-test-scope-and-real-io.md)
  rules `eta_test` deterministic-only: a documented recipe, a helper package,
  or nothing. Graduates when that ticket resolves.
- Package splits that candidate tickets can graduate. Example: a new
  `eta_otel_env` package if [Observability bootstrap](issues/07-observability-bootstrap.md)
  keeps env-driven init out of `eta_otel`.
- Prototype follow-ups for any candidate whose decision needs code to react
  to.

## Out of scope

- Implementing the component loader. The specs live in
  `docs/issues/eta-component-runtime/`.
- Redesigning `Effect` core semantics.
- App-specific helpers. Consumer code stays in the consumer projects.
- Implementing any accepted API. This map is a decision set, not a build
  plan.
- The component-runtime design work of the sibling effort
  `docs/wayfinder/eta-component-runtime/`.
