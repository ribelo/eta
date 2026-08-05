# Production request-cancellation contract

Type: grilling
Status: resolved
Blocked by: 02

## Question

What exact production contract makes `Supervisor.Scope.request_cancel`
implementation-ready?

Decide:

- the exact public type and module placement.
- the cancellation-request linearization point.
- idempotence and repeated-request behavior.
- races with normal completion and child failure.
- the relation between `request_cancel`, `cancel`, and `await`.
- error and complete `Eta.Cause` preservation.
- ordering for several request operations in one scope program.
- backend obligations and portability constraints.
- negative type checks that preserve structured ownership.
- named executable laws and required law-registry rows.
- the focused and repository-wide production verification commands.

The contract must remain backend-neutral. It must not expose a runtime scope,
cancellation token, or detach operation.

## Answer

### Public API

Add this operation to `Supervisor` in the root `eta` package:

```ocaml
val request_cancel :
  ('s, 'err, 'a) child -> ('s, unit, 'outer_err) Scope.t
```

The public interface documentation must state these laws:

```ocaml
(** Request cancellation of [child] and return after the request is latched.
    This operation does not wait for child settlement or finalizers.

    Repeated requests are idempotent. A settled child keeps its terminal
    outcome.

    A later [cancel child] remains the settlement fence and preserves failure
    diagnostics. A later [await child] observes the ordinary child outcome,
    including interruption when cancellation wins.

    Scope sequencing orders request points. This order does not order when
    different children observe interruption or run finalizers. *)
```

The operation returns `unit` and introduces no typed error. The surrounding
scope keeps its existing error type.

The existing rank-two brand remains the only ownership token. The API exposes
no runtime scope, cancellation context, switch, or detach operation.

The user approved this contract after the grilling review.

### Request point and ordering

The operation linearizes when the existing child cancellation callback latches
the request. `Scope.t` returns only after that callback returns.

If runtime contexts exist, the callback requests cancellation from both
contexts before it returns. If they do not exist, the child checks the latch
before it starts its body.

The request point does not prove that the child observed interruption. It also
does not wait for child cleanup, terminal publication, or failure recording.

`Scope.bind` orders several request points in program order. The runtime keeps
its normal scheduling freedom after each request point. Sibling interruption
observations and finalizers have no cross-child order.

### Completion, failure, and repeated requests

The first terminal publication keeps winning each child race.

- Completion before the request remains completion.
- Typed failure or defect before the request remains that failure.
- A request that wins produces the existing interruption outcome.
- A finalizer failure keeps its complete diagnostic position in `Eta.Cause`.
- Later requests do not change the winner or run cleanup again.

`request_cancel child` never reads or rewrites the child result.

`cancel child` requests cancellation again and then waits for settlement. The
second request is harmless. Pure interruption keeps the existing successful
cancellation acknowledgement. Other child and finalizer causes remain intact.

`await child` waits for the ordinary child result. It reports interruption when
the request wins. Existing supervisor failure observation remains unchanged.

Leaving `Supervisor.scoped` remains the final ownership fence. Scope exit waits
for every owned child and finalizer, including previously requested children.

### Backend obligations

No new `Runtime_contract` operation is required.

The existing child callback must latch cancellation before returning. Repeated
calls must remain idempotent. A call for an already settled child must not alter
that result.

The production change must make two existing backend obligations explicit in
`runtime_contract.mli`:

- `cancel` records a cancellation request and returns without target settlement.
- `fail_scope` records failure, requests cancellation, and returns without scope
  settlement.

The public nonwaiting test exercises both operations through the child callback.
The same test must pass with the native Eio and JavaScript backends.

All callback and scope operations keep their existing owner-domain restriction.
The new operation adds no portability or domain-safe capability.

### Production change set

The implementation changes these files:

- `lib/eta/effect_supervisor_scope.ml` adds the instruction and interpreter case.
- `lib/eta/effect_erasure.ml` erases the new instruction.
- `lib/eta/supervisor.ml` exposes the smart constructor.
- `lib/eta/supervisor.mli` exposes the type and approved laws.
- `lib/eta/runtime_contract.mli` states the request-only backend obligations.

The interpreter calls `Runtime_supervisor.child_cancel`. No runtime backend or
`Runtime_supervisor` implementation change is required.

### Structured-ownership checks

The operation accepts a branded child and returns only `unit`. It creates no new
escape path.

The existing negative fixtures must still fail with their stored diagnostics:

- `supervisor_return.ml`
- `supervisor_ref_leak.ml`
- `supervisor_escape_type_s.ml`

These fixtures already prove that callers cannot move a child outside its
supervisor brand. A new negative fixture does not distinguish this operation.

### Executable laws

Add this generated law to `test/laws/law_properties.ml`:

- `Supervisor request_cancel repeated requests equal one request across generated counts and terminal outcomes`

Generate request counts from one through eight. Generate completion, typed
failure, clean interruption, and failing-finalizer outcomes. Compare exact exits,
event counts, finalizer counts, and the available empty fiber census.

Add these exact named tests to
`test/core_common/supervisor_common_suites.ml`:

- `request_cancel latches before child start`
- `request_cancel returns before settlement`
- `request_cancel preserves terminal winners`
- `cancel after request_cancel preserves settlement diagnostics`
- `await after request_cancel reports interruption`
- `request_cancel calls follow scope program order`

Add equivalent tests with the same names to `test/js_jsoo/test_eta_jsoo.ml`.
The JavaScript tests must hold settlement with a promise, not a timer.

Each outcome matrix must execute every documented branch. Failure messages must
print the request count, terminal class, exact exit, and event trace.

### Law registry

Update `.scratch/research/dx/e22/review/LAWS.md` in the production change. Use
the next free identifiers recorded by this decision:

- `M128` for generated repeated-request idempotence.
- `R181` for request latching and nonwaiting return.
- `R182` for first-terminal-outcome preservation.
- `R183` for the later `cancel` settlement and diagnostic fence.
- `R184` for the later `await` outcome.
- `R185` for request-point order and unspecified target observation order.
- `R186` for request-only `Runtime_contract.cancel`.
- `R187` for request-only `Runtime_contract.fail_scope`.

Each row must cite its exact final interface span and named test span. Update the
registry counts after the rows land. Do not place these claims in dated debt.

### Acceptance trace

| General acceptance scenario | Required evidence |
| --- | --- |
| Ownership admission completes before deactivation starts. | Existing atomic-registration evidence plus `request_cancel latches before child start`. |
| Every deactivation request returns before replacement work starts. | `request_cancel calls follow scope program order`. |
| Replacement work can overlap old cleanup. | `request_cancel returns before settlement`. |
| A later fence settles all old work. | `cancel after request_cancel preserves settlement diagnostics`. |
| Failure and cleanup diagnostics survive overlap. | Terminal-winner and settlement-diagnostic matrices. |
| Final shutdown leaves no owned work. | Generated empty-census checks plus existing scoped-shutdown tests. |

These scenarios contain only general Eta lifecycle terms. The Eta Crux map can
point to this trace without adding application concepts to Eta.

### Production verification

Run the focused gates first:

```sh
nix develop -c dune runtest test/core_eio test/laws test/type_errors --force
```

Then run every repository gate required for this core change:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
```

The production handoff must record each command, compiler version, exit status,
and final commit.
