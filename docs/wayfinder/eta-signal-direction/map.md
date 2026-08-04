# Eta Signal evidence and direction map

## Destination

An evidence-backed, implementation-ready direction for Eta Signal. The effort
must verify the independent review, decide which gaps matter, and follow each
accepted consequence until no design decision blocks implementation.

## Notes

The starting evidence is the
[independent review](../../../.scratch/research/eta-signal-direction/independent-review.md)
of repository commit `4197be98`. The review is an input, not an authority.

The effort starts with F1-F14 and N1-N5. It can include an adjacent gap when
that gap is necessary for a complete invariant, interface, or design. Jane
Street Incremental is a source of semantics, counterexamples, and performance
ideas. It is not a compatibility target.

The scope includes `eta_signal`, `eta_signal_map`, and affected Eta Crux design.
The active SecondAgent implementation is evidence and a source of scenarios. It
does not constrain the final design. Existing requirements, ADRs, PRDs, and
Wayfinder decisions are prior evidence that this effort can reopen.

Planning is the deliverable. Research and throwaway prototypes can supply
evidence. Production code and durable tests are implementation work.

Eta prefers deep modules. A deep module gives consumers a small interface and
hides complex behavior behind strong invariants. Internal modules must preserve
locality and must each own a named invariant. Eta accepts maintainer complexity
when that complexity gives consumers a simpler interface. A local correction is
not sufficient when it preserves scattered invariants, shallow modules, or an
incoherent interface.

Eta is a library. External consumer usefulness is the primary test for an
interface or capability. Repository use search records current implementation
use only. The absence of an internal consumer is not evidence against a
capability. It can prompt an evaluation of Eta's own use of the capability.
Absence alone answers neither question.

For a private abstraction, no production instantiation identifies a design
question. The options include deliberate private retention, canonical adoption,
promotion to a public deep interface, replacement, and removal. Use count does
not decide that question. For a public interface, external leverage, coherent
semantics, safety, and depth decide retention and addition.

A gap can earn work through external consumer utility, correctness, a declared
law, asymptotic behavior, architectural depth, or coherent interface
completeness. Reference-library parity does not earn work by itself. Every
confirmed correctness defect needs a disposition. Severity, reachability,
likelihood, and repair dependencies decide the sequence.

Use executable counterexamples and operation counts when possible. Use static
reasoning for architecture and interface claims. When implementation, tests,
and prose disagree, treat each artifact as evidence and decide the desired
contract from first principles.

[Complete repository evidence](issues/01-complete-repository-evidence.md) owns
review traceability. Its claim census must cover every substantive claim in all
seven review sections. Each row must have an exact source span, one owner, and a
final disposition. A ticket answer must cite each census row that it resolves.
This map is not complete while a census row is unowned or unresolved.

Use `$prototype` for prototype tickets and `$research` for research tickets.
Use `$batch-grill-me`, `$domain-modeling`, and `$codebase-design` for grilling
tickets. Use `$simple-english` for written artifacts. Keep durable research in
`.scratch/research/eta-signal-direction/`. Keep throwaway prototypes outside the
main Dune workspace.

## Decisions so far

- **Library consumer criterion.** External consumer usefulness is primary.
  Repository use is inventory. Internal absence cannot justify rejection,
  omission, or deletion.
- [Complete repository evidence](issues/01-complete-repository-evidence.md) —
  The packed, probe, and evidence-baseline Signal trees are identical. F3 is
  explicit but incomplete debt. Five F6 functors have test-only consumers. The
  F6 result is inventory, not a deletion decision. The claim census gives every
  review claim one owner.
- [Atomic phase entry](issues/02-atomic-phase-entry.md) — N1 is confirmed by
  execution. Identity exhaustion escapes as a defect and wedges the graph in the
  pure phase permanently. Identity construction must precede phase mutation, and
  phase entry must return a live transaction or preserve the idle state exactly.
  A fresh physical token removes the counter and the shared allocator, but it
  does not replace that ordering invariant.
- [Keyed removal with a nested bind switch](issues/03-keyed-bind-invalidation.md)
  — N2 is confirmed by execution. The current order commits a staged bind after
  keyed removal invalidates its owner. The result retains invalid bind edges and
  a valid provisional scope under an invalid parent, with no pending transaction
  work. One fixed invalidation frontier must decide commit or discard before
  topology mutation. Public DOT and node counts omit the retained edge, so the
  final gate needs direct topology evidence or corrected diagnostics.

## Not yet specified

- **The final correction program.** The evidence and design tickets must first
  decide which review findings survive, which new gaps matter, and whether the
  result is a correction or a redesign.
- **Migration and implementation slices.** Their shape depends on the final
  interfaces and internal module ownership. The repository does not keep
  compatibility paths.

## Out of scope

- Production implementation and durable test changes during this planning
  effort.
- Compatibility with the Jane Street Incremental interface.
- Compatibility shims for current Eta Signal callers.
- Unrelated changes to the root Eta runtime.
- Eta Crux rendering, host adapters, and application features that do not depend
  on the Signal direction.
