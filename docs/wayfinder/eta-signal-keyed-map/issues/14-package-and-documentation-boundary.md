# Package and documentation boundary

Type: grilling
Status: resolved
Blocked by: 09, 10, 11, 12, 13

## Question

What final package, library, test, benchmark, requirement, and ADR layout makes
the design implementation-ready?

Fix the Dune and opam dependency graph for `eta_signal`, `eta_signal_map`, Eta
Crux, and test support. Root `eta` must not gain the map or keyed operator.

Identify the canonical public `.mli` files, law suites, benchmark targets, Nix
gates, and executable-law registry rows.

Decide which provisional statements in these sources are replaced:

- [Keyed assoc and stable child identity](../../eta-crux-first-principles/issues/04-keyed-assoc-contract.md)
- [Engine strategy](../../../requirements/eta-crux/engine-strategy.md)
- [eta_signal_map and minimal eta_signal hook contract](../../eta-crux/issues/16-eta-signal-map-contract.md)

Name any ADR that the final tradeoffs justify. Do not write implementation
requirements for another package inside the Eta Crux requirement bundle.

Record the two external Eta Crux decisions named by the map as consumer
prerequisites. Do not resolve them in this effort.

The answer must leave no package or documentation ownership decision for
implementation.

## Answer

### Package and library graph

Publish one new sibling package. Its opam package, public Dune library, and
top-level OCaml module use the same name:

| Artifact | Direct package dependencies | Installed surface |
|---|---|---|
| `eta` | OCaml | Existing `eta` surface only. |
| `eta_signal` | `eta`, `eta_stream` | Public `eta_signal` plus its package-private kernel. |
| `eta_signal_map` | `eta_signal` at exactly the same version | Public `eta_signal_map`. |
| Eta Crux plain-state V1 | None of the signal packages | No graph-backend dependency. |
| A later Eta Crux graph backend | `eta_signal_map` | Private translation from `Assoc(Order).assoc` to the keyed operator. |

The root `eta` package does not gain a map, keyed operator, or dependency on
either signal package. `eta_signal` does not depend on `eta_signal_map`.

Add this generated-package source to `dune-project`:

```lisp
(package
 (name eta_signal_map)
 (synopsis "Keyed incremental maps for Eta Signal")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.0))
  (eta_signal (= :version))
  (alcotest :with-test)
  (qcheck :with-test)))
```

`eta_signal_map.opam` remains generated. Do not edit it directly. The exact
version constraint is required because the package compiles against an
`eta_signal` package-private CMI.

Use these source and Dune boundaries:

- `lib/signal/kernel/` owns the private `eta_signal_kernel` library.
- That library has `(package eta_signal)` and no `public_name`.
- Dune installs it as `eta_signal.__private__.eta_signal_kernel`.
- `lib/signal/` keeps the public `eta_signal` library and `Eta_signal` module.
- `lib/signal_map/` owns public library `eta_signal_map` and module
  `Eta_signal_map`.
- The `eta_signal_map` library depends on `eta_signal` and
  `eta_signal_kernel`.
- Public CMIs do not expose a private-kernel path or type.

The private kernel is not a third opam package. There is no public graph,
scope, node, transaction, or extension-capability library.

Plain-state Eta Crux V1 does not select a signal factory. It therefore gains no
dependency in this change. A later graph backend depends directly on
`eta_signal_map`, not on `eta_signal` alone. Eta Crux ticket 15 owns the name and
placement of that backend package.

### Canonical public documentation

These files own the public contract:

- `lib/signal/eta_signal.mli` owns the common graph and diagnostics surface.
- `lib/signal_map/eta_signal_map.mli` owns `Map`, the richer graph factory, and
  `Keyed(Order).mapi`.
- `lib/signal_map/README.md` owns installation and usage examples.
- `docs/packages.md` owns package discovery, direct dependencies, and a minimal
  usage recipe.

The `.mli` files are authoritative when an example and an interface disagree.
The README must link to the public interfaces. It must not restate behavioral
laws in different words.

Add one entry under `CHANGELOG.md` > `Unreleased` > `Added` when the package
ships. The entry names `eta_signal_map`, its map, and the keyed operator. It
links to the package guide instead of repeating the law set.

### Requirements ownership

Create these package-owned requirement bundles with the implementation:

- `docs/requirements/eta-signal/README.md`
- `docs/requirements/eta-signal/keyed-extension.md`
- `docs/requirements/eta-signal-map/README.md`
- `docs/requirements/eta-signal-map/keyed-map.md`

`keyed-extension.md` owns the private kernel, transaction seam, affected-child
notification, and common diagnostics requirements. `keyed-map.md` owns the map,
keyed operator, observability, and complexity requirements.

The Eta Crux requirement bundle keeps only consumer obligations. In
`engine-strategy.md`, retain these requirements:

- Eta Crux consumes the sibling substrate when its graph backend supports keyed
  collections (`eng-8w2n`).
- Eta Crux implements `assoc` over that substrate (`eng-b4r9`).
- The graph engine provides the required timer wake information (`eng-6h8t`).

Move these requirements out of the Eta Crux bundle:

- `eng-3p7k` and `eng-c1m6` move to
  `docs/requirements/eta-signal/keyed-extension.md`.
- `eng-m5k7`, `eng-r9p2`, `eng-c6v1`, and `eng-n3d8` move to
  `docs/requirements/eta-signal-map/keyed-map.md`.

Preserve each requirement ID during the move. Update links and frontmatter in
the same change. Do not leave duplicate normative copies in
`engine-strategy.md`.

Eta Crux issue 16 has three outcomes:

- This effort resolves its Eta Signal hook question through ticket 07 and the
  affected-child requirement from ticket 11.
- This effort resolves its key discipline through tickets 06 and 08.
- Its timer-wake question remains an Eta Crux decision.

Remove the first two questions and the requirements-ownership question from
issue 16 when its map is updated. Keep or move the timer question within the
Eta Crux effort. This effort does not decide that timer interface.

### Replacement of provisional decisions

The first-principles `04-keyed-assoc-contract.md` remains authoritative for
continuous-key child identity, scope incarnation, final-snapshot behavior,
removal, re-entry, and transaction atomicity.

This effort replaces these provisional parts of ticket 04:

- The caller-owned `Stdlib.Map.S` input is replaced by
  `Eta_signal_map.Map.Make(Order)`.
- `data_equal` is replaced by the directed `data_cutoff` contract.
- The private Eta Crux `Keyed_map.create` location is replaced by the private
  translation to `Keyed(Order).mapi`.
- Linear `Stdlib.Map.merge` reconciliation is replaced by ticket 11's bounded
  shared-ancestry path and correct linear independent-map path.
- The provisional package-location question is replaced by the graph in this
  answer.

The identity and lifecycle laws are not replaced. Eta Crux action delivery and
dynamic work ownership remain external consumer decisions.

### Test ownership

Do not publish an `eta_signal_map_test` package. Test helpers remain private to
the repository.

Use these law suites:

- `test/laws/map_semantic_properties.ml` contains ticket 09's 22 public map
  properties.
- `test/laws/map_representation_properties.ml` contains ticket 09's eight
  private representation properties.
- `test/laws/keyed_mapi_properties.ml` contains ticket 10's 37 claim-specific
  properties.
- `test/laws/keyed_mapi_model_properties.ml` contains
  `keyed_mapi_model_trace_matches_runtime`.

Use `test/signal_map/` for fixed and interface checks:

- `test_eta_signal_map.ml` contains the six clean-room map regressions.
- `test_eta_signal_map_diagnostics.ml` contains ticket 13's 11 diagnostics
  tests.
- `negative/run.sh` owns the two map functor compiler tests and the private-CMI
  boundary checks.
- `support/` owns the private invariant, identity, event-recorder, failpoint,
  and overflow harnesses used by those suites.

Keep the generic transaction tests in their current `test/signal/` locations.
Add `test_commit_is_total_after_preflight` and
`test_preflight_orders_owner_before_descendant` there, as ticket 10 requires.

The new test stanzas use `eta_signal_map`, `alcotest`, `qcheck`, and
`qcheck-core.runner`. They may use package-private test libraries from
`test/signal_map/support/`. They do not create an installed test dependency.

### Benchmark and verification targets

Put the production benchmark at
`lib/signal_map/bench/bench_signal_map.ml`. One executable has two modes:

- `@signal-map-complexity` runs ticket 11's deterministic comparison-count and
  child-visit gates.
- `@bench` runs supporting wall-time measurements.

The deterministic target is a required gate. Wall time cannot fail the
complexity contract. The prototype results remain design evidence and are not
the production gate.

Add `eta_signal_map` to `etaPackageNames` and the default
`ETA_OPAM_PACKAGES` list in `flake.nix`. Add its library, tests, and deterministic
gate to `eta-oxcaml-test-shipped`.

The required repository checks are:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c dune build @signal-map-complexity
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c eta-mainline-test-shipped
```

The mainline script already builds `@install`, runs all tests, and builds
`@bench`. Extend it to build `@signal-map-complexity` explicitly.

The focused `eta-ocaml54-test-erg` gate stays unchanged until an Erg-owned
package consumes `eta_signal_map`. There is no JavaScript-specific package or
gate in V1.

### Executable-law registry

Update `.scratch/research/dx/e22/review/LAWS.md` in the same implementation
change as each public claim. Use exact source spans and these evidence groups:

- `Eta_signal_map.Map` rows cite the ticket 09 properties and fixed tests.
- `Keyed(Order).mapi` rows cite the ticket 10 properties or an authoritative
  generic transaction test.
- Public diagnostics rows cite the ticket 13 tests.
- Public complexity rows cite `@signal-map-complexity` and its exact benchmark
  assertion.
- Compiler-boundary rows cite the named negative tests.

Do not add placeholders or new dated debt. A private representation claim must
state its private observation boundary in the registry.

### ADR and external Eta Crux prerequisites

Reserve this ADR path and title:

```text
docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md
Lean Eta Signal with a sibling Eta Signal Map
```

Eta Crux ticket 15 owns writing the ADR. It records the package boundary,
private-kernel tradeoff, and rejection of putting keyed collections in
`eta_signal`.

Two Eta Crux decisions remain external prerequisites:

- [Action injection and staged Eta effects](../../eta-crux-first-principles/issues/05-action-effect-protocol.md)
- [Dynamic lifetime and work ownership](../../eta-crux-first-principles/issues/07-dynamic-lifetime-ownership.md)

They own action delivery, cancellation, and lifecycle-hook payloads. They do
not block implementation or release of `eta_signal_map` itself. This effort does
not resolve them.
