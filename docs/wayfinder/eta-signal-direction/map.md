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

A gap can earn work through correctness, a declared law, asymptotic behavior,
architectural depth, or coherent interface completeness. Reference-library
parity does not earn work by itself. Every confirmed correctness defect needs a
disposition. Severity, reachability, likelihood, and repair dependencies decide
the sequence.

Use executable counterexamples and operation counts when possible. Use static
reasoning for architecture and interface claims. When implementation, tests,
and prose disagree, treat each artifact as evidence and decide the desired
contract from first principles.

Use `$prototype` for prototype tickets and `$research` for research tickets.
Use `$batch-grill-me`, `$domain-modeling`, and `$codebase-design` for grilling
tickets. Use `$simple-english` for written artifacts. Keep durable research in
`.scratch/research/eta-signal-direction/`. Keep throwaway prototypes outside the
main Dune workspace.

## Decisions so far

<!-- Add one context pointer for each resolved ticket. -->

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
