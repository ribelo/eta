---
kind: issue
status: ready-for-agent
requirements:
  - ecnat-s879
  - ecnat-baq2
  - ecnat-hofc
  - ecnat-dsys
  - ecnat-o3sk
  - ecnat-t968
  - ecnat-cd44
  - ecnat-ilm4
  - ecnat-xtln
  - ecnat-74ep
  - ecnat-ijch
  - ecnat-be6t
  - ecnat-n8xk
  - ecnat-uho5
  - ecnat-k11m
  - ecnat-s256
  - ecnat-mapz
  - ecnat-livq
  - ecnat-nbzj
  - ecnat-e4vc
  - ecnat-ijdk
  - ecnat-gk1j
  - ecnat-4eg3
  - ecnat-jf6y
  - ecnat-6tvh
  - ecnat-7qin
  - ecnat-ysgp
  - ecnat-gwsh
  - ecnat-aepr
  - ecnat-gwh6
  - ecnat-o3uo
  - ecnat-d67w
  - ecnat-lqik
  - ecnat-39a1
  - ecnat-mn2e
  - ecnat-qjw0
  - ecnat-v5g5
  - ecnat-4ycg
  - ecnat-00fq
  - ecnat-n5w7
  - ecnat-f7ns
  - ecnat-pqag
  - ecnat-lqg8
  - ecnat-oqsi
  - ecnat-3n83
  - ecnat-d2jz
  - ecnat-r24b
  - ecnat-vl10
---

# Eta component native loader and HMR

## Problem Statement

A native OCaml service cannot replace the code of a running component without
help. `Dynlink` loads a unit, but nothing connects a build result to a
component-context change safely:

- File-watch events are not source truth. Event order, partial writes, and
  coalesced notifications make the file system an unreliable description of
  what was built.
- A load can break type identity. If a hot-replaceable configuration type,
  coeffect descriptor, or component family is rebuilt, the new unit and the
  running process disagree about types that the runtime treats as equal.
- Registration is unbounded. A plugin initializer can register nothing, several
  declarations, an unauthorized family, or a declaration at the wrong time, and
  nothing binds a loaded artifact to the replacement target it must satisfy.
- Native code never goes away. After a failed load or a rollback, machine code,
  module globals, frame tables, and GC roots can stay resident, and the operator
  has no report of what remains.
- Loading and replacing are different failures. A native load failure must not
  look like a component activation failure, and neither must silently mutate
  lifecycle state.

## Solution

Ship the optional `eta_component_loader_native` package. It exposes
`Eta_component_loader_native`: an adapter for `Eta_component_loader` that turns
an authoritative build manifest into a validated replacement batch and loads
its artifacts privately.

The application supplies dirty signals and one Eta effect that reads a
`Manifest.t`. The adapter treats a dirty value only as a rescan request and the
manifest as the authoritative build state. It classifies the complete dependency
closure: a private-module change rebuilds each affected declaration, a
stable-host-interface or runtime change returns `Needs_restart`, and an unknown
dependency rejects the revision.

Before any native mutation the adapter compares the manifest with a `Host.t`
description of the running process. It copies each build artifact to a
package-owned immutable generation path, calls `Dynlink.loadfile_private`, and
authorizes exactly one `Plugin.register` call per load, bound to one target, one
stable module locator, one artifact, and one unique compilation unit. Every
result — including a partial load — reports artifact residency, because only a
process restart reclaims native code.

## Requirements

In this section, "the system" is the `eta_component_loader_native` package: the
`Eta_component_loader_native` façade, its private modules, and the
`eta_component`, `eta_component_loader`, and `dynlink` seams it uses.

### Package and surface

- The system shall publish the optional `eta_component_loader_native` package with one public Dune library and one `Eta_component_loader_native` top-level façade. ^ecnat-s879
- The system shall declare `eta`, `dynlink`, the same-version `eta_component`, and the same-version `eta_component_loader` as its only package dependencies. ^ecnat-baq2
- The system shall install with no Eio, watcher-library, or serialization-codec dependency. ^ecnat-hofc
- The system shall expose the host description, dependency classification, artifact, manifest, plugin registration, source contract, and native error types through the façade. ^ecnat-dsys
- The system shall keep the manifest, classification, plugin, dynlink, and residency implementation modules private to the package. ^ecnat-o3sk
- The system shall supply one `Eta_component_loader.ADAPTER` implementation from `Make (Source : SOURCE)`. ^ecnat-t968

### Manifest authority

- The system shall treat a dirty source value only as a rescan request. ^ecnat-cd44
- When a dirty signal arrives, the system shall invoke the application manifest effect and shall treat its result as the authoritative build state. ^ecnat-ilm4
- The system shall derive no source truth from file-watch event order. ^ecnat-xtln
- The system shall accept a manifest that carries one source revision, one build revision, its changed units, its dependency records, and its artifacts. ^ecnat-74ep
- If a manifest repeats a compilation unit, then the system shall return `Duplicate_unit` with that unit name. ^ecnat-ijch
- If a manifest names a required unit that it does not describe, then the system shall return `Missing_dependency` with that unit name. ^ecnat-be6t
- If a manifest repeats a replacement target entry, then the system shall return `Duplicate_target` with that entry identifier. ^ecnat-n8xk
- If the manifest read fails, then the system shall reject that source revision with `Source_error` and shall perform no native mutation. ^ecnat-uho5
- The system shall treat manifest unit names as diagnostic data that establish no type identity. ^ecnat-k11m

### Dependency classification

- When a changed unit is a private module, the system shall rebuild every declaration whose dependency closure contains that unit. ^ecnat-s256
- When a changed unit is a stable host interface or a runtime module, the system shall return `Needs_restart` for that source revision. ^ecnat-mapz
- If a dependency record has an unknown kind, then the system shall reject that source revision with `Unknown_dependency` and that unit name. ^ecnat-livq
- The system shall classify the complete dependency closure before it prepares any candidate. ^ecnat-nbzj

### Host compatibility

- The system shall compare the manifest with the `Host.t` compiler, target, plugin magic, stable-interface digest, and allowed units before any native mutation. ^ecnat-e4vc
- If a host comparison fails, then the system shall reject that source revision with `Host_mismatch` and the mismatching fact. ^ecnat-ijdk
- The system shall require every hot-replaceable configuration type, coeffect descriptor, and `Component.Family.t` value to live in the stable host interface. ^ecnat-gk1j
- The system shall require every native generation to import the same stable interface files. ^ecnat-4eg3
- When a stable host interface changes, the system shall require a process restart. ^ecnat-jf6y

### Private loading and registration

- Before loading, the system shall copy each build artifact to a package-owned immutable generation path. ^ecnat-6tvh
- The system shall load each artifact through `Dynlink.loadfile_private`. ^ecnat-7qin
- The system shall load every candidate of one source revision before it requests any component-context change. ^ecnat-ysgp
- The system shall authorize exactly one `Plugin.register` call for each private load. ^ecnat-gwsh
- The system shall bind each load token to one replacement target, one stable module locator, one artifact, and one unique compilation unit. ^ecnat-aepr
- If `Plugin.register` runs outside an authorized load, then the system shall return `Registration_outside_load` and shall reject that load. ^ecnat-gwh6
- If `Plugin.register` runs twice within one authorized load, then the system shall return `Duplicate_registration` and shall reject that load. ^ecnat-o3uo
- If a registered component family or module locator differs from its target values, then the system shall return `Unauthorized_family` and shall reject that load. ^ecnat-d67w
- If an authorized load registers no declaration, then the system shall reject that source revision with `Missing_registration` and that unit name. ^ecnat-lqik
- If a native load raises, then the system shall reject that source revision with `Native_load_failed` carrying the artifact and the message. ^ecnat-39a1
- If a candidate does not match its replacement target, then the system shall reject that source revision with `Candidate_mismatch` and that entry identifier. ^ecnat-mn2e
- If any candidate of one source revision is rejected, then the system shall reject the complete source revision and shall leave every accepted desired state and component instance unchanged. ^ecnat-qjw0
- The system shall document that a plugin initializer must only register its inactive declaration and must run no component effect. ^ecnat-v5g5

### Residency reporting

- When a native load succeeds, the system shall report `Retained` residency for each loaded artifact. ^ecnat-4ycg
- When a candidate becomes unreachable after rejection or rollback, the system shall report `Unreachable_but_loaded` residency for its artifacts. ^ecnat-00fq
- If the native loader cannot determine an artifact state, then the system shall report `Unknown` residency for it. ^ecnat-n5w7
- When an initializer fails, the system shall report the residency of every known artifact of that load. ^ecnat-f7ns
- The system shall unload no native code. ^ecnat-pqag
- The system shall report that only a process restart reclaims native generations. ^ecnat-lqg8

### Prepared output

- When classification, host comparison, loading, and registration succeed, the system shall return one `Ready` preparation whose prepared value is one `Eta_component.Replacement.batch`. ^ecnat-oqsi
- The system shall stamp that batch with the manifest source revision. ^ecnat-3n83
- The system shall build each candidate from one packed replacement target and one packed registered component. ^ecnat-d2jz
- When the system rejects a source revision, it shall return one `Rejected` preparation that names the rejection stage, the native error, and the artifact list. ^ecnat-r24b
- The system shall request no component-context change for a `Rejected` or `Needs_restart` preparation. ^ecnat-vl10

## Implementation Decisions

The normative interface is the `eta_component_loader_native` section of the
approved
[integrated handoff](../../wayfinder/eta-component-runtime/assets/integrated-handoff.md).
The loading, classification, and retention conclusions come from
[Native loading and HMR](../../wayfinder/eta-component-runtime/issues/07-native-loading-and-hmr.md)
and
[Module replacement and rollback](../../wayfinder/eta-component-runtime/issues/17-module-replacement-and-rollback.md).

**Package.** One optional package, one public library, one
`Eta_component_loader_native` façade, dependencies `eta`, `dynlink`, and the two
same-version component packages. Private modules: manifest, classification,
plugin, dynlink, residency.

**Authority split.** The application owns source I/O, decoding, and dirty-signal
production, and supplies one Eta effect that produces `Manifest.t`. The adapter
owns manifest-read timing, validation, classification, revision admission,
artifact naming, private `Dynlink` mutation, and residency accounting. The
component core owns fencing, staging, publication, rollback, and restoration.

**Stable host interface.** A non-reloadable stable interface owns every
hot-replaceable configuration type, coeffect descriptor, and
`Component.Family.t` value; the family also owns the authorized stable module
locator. Every generation imports the same `.cmi` files, and a change to them
requires process restart.

**Load token.** One private token per `Dynlink.loadfile_private` call authorizes
exactly one `Plugin.register` call and binds target, locator, artifact, and
compilation unit. Registration outside a load, no registration, repeated
registration, and family or locator mismatch are all explicit failures.

**Trust boundary.** Eta cannot enforce "the initializer runs no component
effect" against trusted native code. The rule is documented, and initializer
failure reports residency instead of pretending the load was clean.

**Retention.** The adapter never unloads native code. Candidate machine code,
module globals, frame tables, GC roots, and code-fragment metadata can stay
resident after rejection or rollback, and a failed load can leave partial code
resident.

This work is step 8 of the integrated handoff implementation sequence and
depends on the two other specs in this directory.

## Testing Decisions

A good test observes the adapter's public results — preparation values, native
errors, residency reports, and the unchanged component-context observations that
a rejection must preserve — and asserts no private loader state. Because native
loading mutates the process, results must be observed in a fresh process.

**Seams** (confirmed with the user):

1. The public adapter surface: `Make (Source).prepare` over scripted
   `SOURCE` implementations and fixture manifests. This is the highest seam and
   carries classification, host, registration, and residency laws.
2. The public `Eta_component_loader` seam for the end-to-end path from a
   submitted native source to an admitted replacement fence.
3. Fresh-process test executables with real built fixture plugins for each
   native result, because `Dynlink` state cannot be reset within one process.
4. The public `Eta_component` diagnostics seam as the oracle for "no core state
   changed" after a native rejection.

**Named gates.** `native_hmr_process_contract` covers stable digest, family,
locator, registration count, and residency, and requires that each result is
reached in a fresh process. `eta_component_shipped_package_contract` covers the
standalone install with only declared dependencies. The replacement outcomes
that follow admission are covered by the core gates
`qcheck_component_hmr_rollback_matrix` and
`qcheck_component_replacement_outcome_precedence`.

**Fixture discipline.** Fixture plugins are built by the test rules, not
checked in as binaries. Each fixture case names one intended failure — wrong
stable digest, wrong family, wrong locator, zero registrations, two
registrations, raising initializer, unknown dependency, stale target — so a pass
cannot come from an unrelated rejection.

**Census discipline.** Every terminal path in the effect-backed part of the
adapter ends with an available empty Eta fiber census.

**Prior art.** `test/eta` for Alcotest plus deterministic runtime helpers,
`test/type_errors` for compile-boundary fixtures, and the existing
process-isolated test executables under `test/` for fresh-process gates.

## Out of Scope

- Unloading native code, reclaiming code fragments, and any zero-residency
  claim.
- Sandboxing untrusted native code and operating-system co-design.
- File watching, dirty-signal production, manifest serialization, and build-tool
  integration.
- Component-local state migration across a replacement.
- Structural interface compatibility checks and provider package versioning. A
  stable-interface change requires restart instead.
- A JavaScript or bytecode hot-replacement path.
- Replacement semantics after admission: fencing, staging, publication,
  rollback, and restoration belong to the core spec.

## Further Notes

Provenance: the
[integrated handoff](../../wayfinder/eta-component-runtime/assets/integrated-handoff.md),
[Native loading and HMR](../../wayfinder/eta-component-runtime/issues/07-native-loading-and-hmr.md),
[Module replacement and rollback](../../wayfinder/eta-component-runtime/issues/17-module-replacement-and-rollback.md),
and
[Package and module ownership](../../wayfinder/eta-component-runtime/issues/19-package-and-module-ownership.md).

Open matter for implementation time: the exact `Host.t` stable-interface digest
computation. The contract requires one digest that changes when any stable
interface file changes; whether it is a digest of the concatenated `.cmi`
contents or of their interface hashes is an implementation choice that the
`native_hmr_process_contract` fixtures must pin.
