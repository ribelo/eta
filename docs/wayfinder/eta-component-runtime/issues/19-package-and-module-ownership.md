# Package and module ownership

Type: grilling
Status: resolved
Blocked by: 15, 16, 17, 18

## Question

Which public packages and private modules own the selected component runtime,
desired-state loader, HMR adapters, and Eio integration?

Start from `eta_component` plus a separate loader package. Apply Eta's
install-only-what-you-use policy. Keep serialization, file watching, native
loading, Eio, and test dependencies in their owning optional packages.

Define public top-level module names and reject dotted public library names.

## Answer

Use three optional packages. Each package has one public library and one
top-level façade. A component package that depends on another component package
requires the same package version.

### Component runtime

`eta_component` exposes `Eta_component`. It depends on `eta` and
`eta_observability`.

The façade owns these public submodules:

- `Coeffect`
- `Requirement`
- `Provision`
- `Activation`
- `Component`
- `Entry_id`
- `Desired_state`
- `Source_revision`
- `Replacement`
- `Context`
- `Diagnostics`

`Source_revision` stays in this package because core replacement admission uses
it. `Replacement` owns fencing, staging, publication, rollback, and restoration.

The package owns built-in component telemetry. It uses `eta_observability`
without exposing telemetry as a second lifecycle or diagnostics authority.

The implementation uses these private module clusters:

- `Component_key_store`, `Component_declaration`, and
  `Component_interception` own typed declarations and storage.
- `Component_admission` and `Component_provider_graph` own desired-state
  validation, realms, provider slots, cycles, committed views, and leases.
- `Component_context_coordinator`, `Component_instance_coordinator`, and
  `Component_generation` own serialized lifecycle work.
- `Component_reconciliation` owns retirement closure and final-snapshot
  reconciliation.
- `Component_replacement` owns transaction-local staging, rollback, and
  restoration.
- `Component_diagnostics` and `Component_telemetry` own immutable observations
  and non-authoritative telemetry.

These modules remain Dune private modules. The package publishes no internal
coordinator, graph, lifecycle, or diagnostics library.

### Generic loader

`eta_component_loader` exposes `Eta_component_loader`. It depends directly on
`eta` and on the same-version `eta_component`.

The façade owns the adapter contract, prepared input, operation identity,
immutable operation, report, failure, artifact, and residency types. It also
owns source supersession and admission linkage.

A loader adapter prepares `Desired_state.t` or `Replacement.batch`. It receives
no `Context.t` and has no component lifecycle authority.

The loader coordinator has one lexical `Eta_component_loader.Make.run`
lifetime. It owns preparation work, source supersession, loader shutdown, and
immutable operation reports. The coordinator, not the adapter, holds the
context authority used for admission.

One loader accepts a strictly increasing source-revision sequence. Equal or
decreasing submissions fail before preparation.

These private modules implement the loader:

- `Component_loader_coordinator`
- `Component_loader_supersession`
- `Component_loader_report`
- `Component_loader_admission`

The package has no serialization, file-watch, native-loading, Eio, or test
library dependency.

### Native loader

`eta_component_loader_native` exposes `Eta_component_loader_native`. It depends
directly on `eta`, `dynlink`, and the two same-version component packages.

The façade owns manifest, dependency-classification, plugin-registration, and
native-load result types. It supplies an adapter for
`Eta_component_loader`.

The application supplies dirty signals and a typed Eta effect that produces one
public `Manifest.t`. The native adapter invokes that effect after each signal
and treats its result as authoritative.

The native adapter owns manifest-read timing, manifest validation,
classification, and revision admission. The application owns source-specific
I/O and decoding into `Manifest.t`. Thus, the package does not depend on Eio, a
watcher library, or a serialization codec.

`Eta_component_loader_native.Plugin` is the stable registration bridge for
plugin initializers. A private load token admits exactly one inactive candidate
for each authorized native load. Registration outside that load, no
registration, or duplicate registration fails explicitly.

A non-reloadable stable host interface owns each hot-replaceable configuration
type, coeffect descriptor, and `Component.Family.t` value. Every native
generation imports the same stable interface. A stable-interface change
requires process restart. Manifest names are diagnostic and do not establish
type identity. The family also owns the stable module locator used for native
authorization.

These private modules implement native loading:

- `Component_loader_native_manifest`
- `Component_loader_native_classification`
- `Component_loader_native_plugin`
- `Component_loader_native_dynlink`
- `Component_loader_native_residency`

The package owns immutable artifact naming, dependency-closure classification,
private `Dynlink` mutation, and residency accounting. It copies each build
artifact to a unique generation path before loading. It cannot unload native
code.

### Eio, formats, watching, and tests

Existing `eta_eio` remains the only Eio runtime adapter. Applications install
`eta_component` and `eta_eio` separately. Neither package depends on the other.

This design adds no `eta_component_eio` package. It also adds no concrete codec
or watcher package.

Applications or later adapter packages own serialization, module resolution,
interpolation, source-specific diagnostics, manifest decoding, and dirty-signal
production. These adapters implement the generic loader or native manifest
seam.

This design adds no `eta_component_test` package. The deterministic reference
model, property tests, and exact-cause probes remain repository tests. A package
declares a test dependency with `:with-test` only when its own tests use that
dependency.

### Naming and dependency direction

The opam package name, Dune public library name, and OCaml top-level module
match for each package. Dotted public library names remain rejected.

The dependency direction is:

```text
eta_component
  -> eta
  -> eta_observability

eta_component_loader
  -> eta
  -> eta_component

eta_component_loader_native
  -> eta
  -> eta_component
  -> eta_component_loader
  -> dynlink
```

`eta`, `eta_observability`, and `eta_eio` do not depend on a component package.
The component runtime does not depend on its loader. The generic loader does
not depend on native loading.
