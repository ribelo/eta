# Current public composition verdict

Type: prototype
Status: claimed
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
