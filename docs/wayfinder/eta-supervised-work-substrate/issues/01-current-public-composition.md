# Current public composition verdict

Type: prototype
Status: resolved
Blocked by:

## Question

Can current public Eta APIs implement a long-lived manager for supervised work
without private runtime access?

Build a throwaway logic prototype with one parent group and nested child groups.
Use only current public Eta APIs in the first version. Compare
`Supervisor.scoped`, `Supervisor.Scope`, `Effect.all`, and `Runtime.drain`.

The prototype must supply visible evidence for these requirements:

- The parent accepts work across multiple admissions during its lifetime.
- The parent creates nested groups and cancels one complete subtree.
- Shutdown waits for all owned work and resources.
- One admission registers all work before any admitted effect body starts.
- Three tagged admission groups start in a defined order. The Crux trace names
  them deactivation, activation, and transition.
- Sibling work runs concurrently after release.
- Outcome races keep the first terminal outcome and the complete `Eta.Cause`.
- OxCaml and upstream OCaml expose the same semantic surface.

Use adversarial order and failure cases. Give the prototype one command that
runs all gates. Use a compiler rejection when the type system supplies the
evidence.

If composition fails, identify the first impossible operation. Explain why
composition cannot restore the missing guarantee.

Record the prototype branch, commit, commands, and results in the answer. If
composition succeeds, also record the complete public composition recipe.

## Answer

### Verdict

Current public Eta interfaces do not satisfy the complete supervised-work
contract.

Public composition satisfies the nearby contracts. The missing operation is a
cancellation request that returns before target settlement and retains a typed
settlement path.

### What composes

A long-lived `Supervisor.scoped` manager can receive several admission effects
through public `Promise` values. Each admission returns after registration while
earlier work remains owned and active.

Nested supervisors preserve the ownership tree. `Supervisor.Scope.cancel`
cancels one nested subtree and returns after its work and resources settle.

`Effect.all` registers every ordinary effect before any body starts. Public
promises add ordered release gates for deactivation, activation, and transition
effect groups. Six sibling bodies remained active together after release.

Public promise resolution preserves the first terminal `Exit.t` and its complete
`Eta.Cause`. `Supervisor.Scope.await` also preserved a primary failure with its
suppressed cleanup failure.

Manager shutdown settled all children and resources before it acknowledged the
stop request. `Runtime.drain` then returned with zero active work and zero
acquired resources.

### First impossible operation

`Supervisor.Scope.cancel` combines two events. It requests cancellation and
waits for complete target settlement.

A caller can fork this operation through `Supervisor.Scope.start`. The fork has
no public acknowledgement after the request and before settlement.

Awaiting the cancellation child waits for target settlement. Continuing after
the fork has no documented guarantee that cancellation precedes activation.

`Effect.all` cannot add the missing point. It accepts `Effect.t`, while
`Supervisor.Scope.cancel` returns `Supervisor.Scope.t`. The negative probe
records this compiler rejection.

Promise gates can mark a point before the cancellation request or after target
settlement. They cannot mark the required point between those events.

Therefore, current public composition cannot request deactivation before new
work starts while old cleanup continues concurrently.

### Evidence

The prototype is on branch
`prototype/eta-supervised-work-current-composition`.

- Code commit: `ecd42b35`
- Results commit: `33e6c918`
- [Prototype results](https://github.com/ribelo/eta/blob/33e6c918/.scratch/research/eta-supervised-work-substrate/current-public-composition/RESULTS.md)

Both commands exited with status `0`:

```sh
nix develop -c bash .scratch/research/eta-supervised-work-substrate/current-public-composition/run.sh
nix develop .#mainline -c bash .scratch/research/eta-supervised-work-substrate/current-public-composition/run.sh
```

The OxCaml shell used OCaml `5.2.0+ox`. The mainline shell used OCaml `5.4.1`.
Both tracks produced the same semantic traces and the same type rejection.

**Minimal general supervised-work interface** must compare Eta interfaces that
expose the missing request point without exposing backend scopes or unscoped
work escape.
