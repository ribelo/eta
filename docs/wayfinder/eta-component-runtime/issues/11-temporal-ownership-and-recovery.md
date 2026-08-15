# Temporal ownership and recovery

Type: prototype
Status: resolved
Blocked by: 03, 04, 06, 08, 09

## Question

What is the smallest context operation that tracks long-lived component effects
while Eta scopes retain lexical resource ownership?

Prototype registration, acquisition, partial activation failure, cancellation,
and repeated disposal. Compare explicit inverse accumulation with scope-owned
finalizers and derived child contexts.

The answer must define at-most-once behavior, recovery order, the observation
boundary, and the contract for an operation that cannot be reversed.

## Answer

Use one public tracked-effect operation, provisionally named
`Activation.own`:

```ocaml
val own :
  Activation.t ->
  acquire:('a, 'error) Effect.t ->
  release:('a -> (unit, 'release_error) Effect.t) ->
  pp_release_error:(Format.formatter -> 'release_error -> unit) ->
  ('a, 'error) Effect.t
```

The public-interface ticket can change the name or exact argument form. It must
preserve the operation below.

### Ownership contract

`Activation.own` admits one tracked effect for the current activation
generation. It adds component semantics to Eta's existing resource operation:

- Before acquisition, it rejects a stale generation or closed admission.
- This rejection is requested lifecycle interruption. It does not widen the
  acquisition-error type.
- A successful acquisition registers its release before it returns.
- The current Eta activation scope owns and runs the release.
- A successful operation that lands after cancellation still registers its
  release.
- Work from a stale generation cannot publish or start another tracked effect.
- Lifecycle diagnostics attribute acquisition and recovery to the component
  instance and generation.

The component runtime does not keep a second inverse stack. It also does not
create one derived component context for each tracked effect. Derived contexts
remain spatial tools for isolation and interception.

`Effect.with_resource` remains the operation for a body-bounded resource.
`Activation.own` is for a tracked effect whose lifetime can extend to activation
settlement.

### Registrations and acquisitions

A registration acquisition returns its registration token. Its release
withdraws that token.

A resource acquisition returns its resource value. Its release uses the
ordinary Eta finalizer contract.

Specialized component operations can use `Activation.own` internally. This
keeps generation checks, recovery ownership, and diagnostics at one mediation
point.

Desired-state reconciliation is the only component-instance creation
authority. `Activation.t` exposes no child-installation operation.

### Failure, cancellation, and repeated disposal

If acquisition fails, it contributes no release. The activation scope still
runs every release from an earlier successful acquisition.

Activation failure closes admission and closes the activation scope. Staged
registrations and provisions do not publish. The component context waits for
scope settlement before it reports the instance as inactive.

Cancellation closes admission before it requests interruption. An operation
admitted before that fence can finish after the request. If it succeeds, its
release joins the scope before recovery starts.

One successful `Activation.own` call registers one release. Eta consumes that
release at most once, including when the release fails. Repeated disposal
requests join or observe one settlement fence. They return the same terminal
outcome and do not run a release again.

The runtime invokes `pp_release_error` at most once for one settled failure
leaf. A raising renderer produces a separate `Renderer_failed` diagnostic. It
does not replace or augment the authoritative finalizer cause.

The scope runs releases serially in reverse registration order. A failed release
does not stop later releases. Eta retains the failure in its finalizer cause.
The component instance settles in a recovery-failed state after the scope
finishes.

This reverse order is local to one activation. Dependency-graph withdrawal
order remains a separate runtime responsibility.

### Observation boundary

Recovery compares the mediated state before activation with the state after
scope settlement. The comparison includes tracked registrations, provisions,
and component-owned state behind declared coeffect operations.

The comparison uses each coeffect's value equivalence. It does not require
physical-state equality. It excludes lifecycle bookkeeping, diagnostics,
allocation identity, and external-emission history.

If a release fails or does not terminate, the runtime makes no recovery
equivalence claim. The settlement result preserves the failure or remains
nonquiescent.

### Irreversible operations

`Activation.own` requires a recovery witness. An operation without a valid
witness cannot claim tracked recovery. The runtime can require the witness, but
it cannot prove that arbitrary native code implements a valid inverse.

An irreversible external emission can run as an ordinary Eta effect. Its
history stays outside the recovery guarantee. An adapter can instead withhold
the emission until commit. Compensation remains outside this design.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-temporal-ownership` at commit `baf744e1`. See the
[prototype source](https://github.com/ribelo/eta/tree/baf744e191b62d08f8806019cc91fde3fda9ae0f/.scratch/eta-component-runtime-temporal-ownership).

The fixed scenarios compared a component inverse stack, Eta scope finalizers,
and derived child contexts. All models produced the required recovery traces.
Only the scope-owned model avoided a second recovery authority without weakening
the observed behavior.

The scenarios covered partial activation failure, cancellation inertia,
repeated disposal, recovery failure, and an irreversible emission. Recovery
occurred in last-in-first-out order. Repeated disposal did not repeat recovery.
