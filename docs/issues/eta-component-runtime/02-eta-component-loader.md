---
kind: issue
status: ready-for-agent
requirements:
  - ecldr-1xyw
  - ecldr-hcqp
  - ecldr-cslh
  - ecldr-iufs
  - ecldr-j483
  - ecldr-rpk9
  - ecldr-wgpq
  - ecldr-u3pj
  - ecldr-dzdn
  - ecldr-bclo
  - ecldr-flzq
  - ecldr-yuyp
  - ecldr-feto
  - ecldr-9se5
  - ecldr-4fjv
  - ecldr-oflp
  - ecldr-zh7a
  - ecldr-1zmh
  - ecldr-oxfx
  - ecldr-cqw8
  - ecldr-a271
  - ecldr-so12
  - ecldr-yer3
  - ecldr-274e
  - ecldr-2g0v
  - ecldr-jq9o
  - ecldr-wvhg
  - ecldr-vk5i
  - ecldr-y34r
  - ecldr-7tze
  - ecldr-xqif
  - ecldr-w6xf
  - ecldr-n3vq
  - ecldr-ckgj
  - ecldr-7967
---

# Eta component generic loader

## Problem Statement

An application that keeps its component composition in an external source — a
configuration file, a service catalogue, a module tree, a build manifest — must
turn that source into an admitted desired state or replacement batch. Doing
this against the component context directly is unsafe:

- Source work can fail, hang, or be cancelled. If the adapter that reads the
  source also holds context authority, a preparation defect can mutate
  lifecycle state or leave a half-applied change.
- Sources change while earlier preparation is still running. Without one
  supersession authority, an old completion can overwrite a newer accepted
  state, and completion order silently becomes lifecycle order.
- Rejection before admission has no report. The application cannot tell
  whether the source was rejected, whether the process must restart, whether
  admission rejected the prepared value, or which fence carries the accepted
  change.
- Preparation work has no lifetime owner. When the application stops, in-flight
  preparation can outlive it.

## Solution

Ship the optional `eta_component_loader` package. It exposes
`Eta_component_loader`: a source-agnostic loader coordinator that owns
preparation work, source supersession, and the link between a prepared value
and component-context admission.

An adapter implements `ADAPTER`: it names its source type and error type, reads
a source revision from a source value, and prepares that source into `Ready`,
`Rejected`, or `Needs_restart`. A `Ready` preparation carries either a
`Desired_state.t` or a `Replacement.batch`, plus artifact residency
information. The adapter receives no component-context authority.

`Make.run` owns one lexical loader lifetime over one component context.
`submit` accepts a strictly increasing source revision and returns one
immutable operation. `await` returns the same immutable report to every waiter,
with one explicit outcome: preparation rejected, native load rejected, stale
candidate, restart required, admission rejected with its typed error, admitted
with its settlement fence, or loader stopped.

## Requirements

In this section, "the system" is the `eta_component_loader` package: the
`Eta_component_loader` façade, its private coordinator modules, and the
`eta_component` and Eta seams it uses.

### Package and surface

- The system shall publish the optional `eta_component_loader` package with one public Dune library and one `Eta_component_loader` top-level façade. ^ecldr-1xyw
- The system shall declare `eta` and the same-version `eta_component` as its only package dependencies. ^ecldr-hcqp
- The system shall install with no serialization, file-watch, native-loading, Eio, or test-framework dependency. ^ecldr-cslh
- The system shall keep the loader coordinator, supersession, report, and admission implementation modules private to the package. ^ecldr-iufs
- The system shall expose the adapter contract, prepared input, operation identity, immutable operation, report, failure, artifact, and residency types through the façade. ^ecldr-j483

### Adapter contract

- The system shall accept one adapter that declares a source type, an error type, a source-revision function, a preparation effect, and an error renderer. ^ecldr-rpk9
- The system shall grant no `Eta_component.Context.t` authority and no component lifecycle operation to an adapter. ^ecldr-wgpq
- The system shall accept a prepared value that is either one `Eta_component.Desired_state.t` or one `Eta_component.Replacement.batch`. ^ecldr-u3pj
- The system shall accept a `Ready` preparation that carries one source revision, an optional build revision, one prepared value, and its artifact list. ^ecldr-dzdn
- The system shall accept a `Rejected` preparation that carries one source revision, an optional build revision, one rejection stage, one adapter error, and its artifact list. ^ecldr-bclo
- The system shall accept a `Needs_restart` preparation that carries one source revision, an optional build revision, and its artifact list. ^ecldr-flzq
- The system shall accept artifact residency `Retained`, `Unreachable_but_loaded`, or `Unknown` for each reported artifact. ^ecldr-yuyp
- The system shall type the preparation effect so that it cannot fail through its typed error channel. ^ecldr-feto

### Loader lifetime

- The system shall create one loader inside one lexical `Make.run` effect over one component context. ^ecldr-9se5
- When the `Make.run` body exits, the system shall close submission, cancel every incomplete preparation, record `Loader_stopped` for every unfinished operation, and wait for loader work to settle. ^ecldr-4fjv
- If `submit` runs after submission closed, then the system shall return `Loader_not_running`. ^ecldr-oflp
- The system shall leak no preparation work past the end of its `Make.run` lifetime. ^ecldr-zh7a

### Submission and supersession

- The system shall create exactly one loader operation for each accepted source revision. ^ecldr-1zmh
- The system shall assign one loader operation identity to each accepted submission. ^ecldr-oxfx
- If a submitted source revision is not greater than the latest accepted revision of that loader, then the system shall return `Source_revision_not_newer` with the latest and the submitted revision. ^ecldr-cqw8
- When the system rejects a submission, it shall run no preparation for it and shall change no component-context state. ^ecldr-a271
- When a later submission is accepted, the system shall supersede incomplete preparation for an earlier revision. ^ecldr-so12
- The system shall define no completion order from revision comparison. ^ecldr-yer3
- When an earlier revision completes preparation after a later revision was accepted, the system shall record `Stale_candidate` for the earlier operation and shall change no component-context state for it. ^ecldr-274e

### Outcomes and reports

- The system shall materialize the complete adapter exit before it completes an operation report. ^ecldr-2g0v
- If a preparation defect occurs, then the system shall record it as an immutable loader failure and shall still produce the operation report. ^ecldr-jq9o
- When a preparation returns `Rejected` at the preparation stage, the system shall record `Preparation_rejected` with its rendered failure. ^ecldr-wvhg
- When a preparation returns `Rejected` at the native-load stage, the system shall record `Native_load_rejected` with its rendered failure. ^ecldr-vk5i
- When a preparation returns `Needs_restart`, the system shall record `Restart_required` and shall submit nothing to the component context. ^ecldr-y34r
- When the system submits a prepared value and the context rejects it, the system shall record `Admission_rejected` with the typed `admission_error`. ^ecldr-7tze
- When the context accepts a prepared value, the system shall record `Admitted` with that settlement fence. ^ecldr-xqif
- If a preparation or load rejection occurs, then the system shall advance no component-context observation revision. ^ecldr-w6xf
- The system shall include the operation identity, the source revision, the optional build revision, the outcome, and the artifact list in every report. ^ecldr-n3vq
- When repeated waits arrive for one loader operation, the system shall return the same immutable report. ^ecldr-ckgj
- The system shall hold the component-context authority in the loader coordinator and shall use it as the only path from a prepared value to admission. ^ecldr-7967

## Implementation Decisions

The normative interface is the `eta_component_loader` section of the approved
[integrated handoff](../../wayfinder/eta-component-runtime/assets/integrated-handoff.md),
and the ownership split is fixed by
[Package and module ownership](../../wayfinder/eta-component-runtime/issues/19-package-and-module-ownership.md).

**Package.** One optional package, one public library, one
`Eta_component_loader` façade, dependencies `eta` and the same-version
`eta_component`. Private modules: loader coordinator, supersession, report, and
admission linkage.

**Authority split.** The adapter owns source I/O, decoding, module resolution,
interpolation, and source-specific diagnostics. The coordinator owns
preparation lifetime, supersession, immutable reports, and admission. The
component context owns every lifecycle fact. An adapter never receives
`Context.t`.

**Functor shape.** `Make (Adapter : ADAPTER)` produces the loader type,
`run`, `submit`, `await`, and the report accessors. Preparation is typed
`(error preparation, never) Eta.Effect.t`, so an adapter cannot fail through
its typed channel and must express rejection as a `Rejected` value. The
uninhabited `never` type is public because the adapter signature needs it.

**Revision authority.** One strictly increasing `Source_revision.t` sequence
per loader. `Source_revision` stays in `eta_component` because core replacement
admission uses it.

**Report shape.** One immutable report per accepted submission, with the
outcome variants `Preparation_rejected`, `Native_load_rejected`,
`Stale_candidate`, `Restart_required`, `Admission_rejected`, `Admitted`, and
`Loader_stopped`. `Admitted` carries the `Diagnostics.Fence.t` so the
application can wait for settlement through the ordinary context seam.

**No adapter packages.** This spec adds no codec, watcher, or file-format
package. Applications and later adapter packages implement `ADAPTER`.

This work is step 7 of the integrated handoff implementation sequence and
depends on the core package spec in this directory.

## Testing Decisions

A good test observes the public loader seam — submission results, operation
reports, and the component-context observations that a rejection must leave
unchanged — and asserts no coordinator internals. Law-bearing prose in
`eta_component_loader.mli` lands with its named gate and registry row in the
same change.

**Seams** (confirmed with the user):

1. The public `Eta_component_loader` surface driven by controlled test
   adapters. A test adapter can complete, fail, raise, hang, or be cancelled on
   command, which is what makes preparation-boundary laws observable.
2. The public `Eta_component` diagnostics seam, used as the oracle for "no core
   state changed" claims: context revision, accepted desired revision, and
   snapshot equality across a rejected submission.
3. The existing `Eta_test.Run` seam for deterministic interleaving and the
   fiber census on loader shutdown.

**Named gates.** `qcheck_component_preparation_revision_fence` covers equal and
decreasing revisions and proves that a stale completion changes no core state.
`eta_test_component_loader_lexical_lifetime` proves that body exit settles every
accepted operation and leaks no preparation work.
`eta_component_shipped_package_contract` covers the standalone install with only
declared dependencies.

**Property discipline.** Generators construct every outcome branch in every
sample, including two overlapping submissions where the earlier one completes
last. Counterexamples print the submission order, the adapter script, the
reports, and the core observations.

**Census discipline.** Every terminal loader path — accepted, rejected,
superseded, stopped — ends with an available empty Eta fiber census.

**Prior art.** `test/laws/law_properties.ml` for registry-backed QCheck
properties, `test/eta` for Alcotest plus deterministic runtime helpers, and the
controlled-source style used by `test/crux` for scripted adapters.

## Out of Scope

- Native loading, manifests, `Dynlink`, and plugin registration. They belong to
  `eta_component_loader_native`.
- Serialization formats, configuration languages, interpolation, module
  resolution, file watching, and dirty-signal production.
- Any lifecycle authority in the loader: it never mutates instances, providers,
  or accepted desired state except through `Eta_component.Context`.
- A public loader event history. Reports are the only public loader
  observation.
- Retry policy for a rejected source revision. A retry needs a fresh, greater
  source revision from the application.
- Concurrent loaders over one context sharing a revision authority. Each loader
  owns its own strictly increasing sequence.

## Further Notes

Provenance: the
[integrated handoff](../../wayfinder/eta-component-runtime/assets/integrated-handoff.md),
[Package and module ownership](../../wayfinder/eta-component-runtime/issues/19-package-and-module-ownership.md),
and
[Operational lifecycle diagnostics](../../wayfinder/eta-component-runtime/issues/23-operational-lifecycle-diagnostics.md)
for the loader-owned pre-admission report.

Open matter for implementation time: whether two loaders over one component
context need a shared revision authority. The current contract gives each
loader its own sequence, and the context still rejects a stale replacement
source revision, so the safe composition is one loader per context.
