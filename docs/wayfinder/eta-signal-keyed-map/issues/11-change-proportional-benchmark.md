# Change-proportional benchmark

Type: prototype
Status: resolved
Blocked by: 05, 08

## Question

What executable benchmark proves the map and keyed-operator reconciliation
claims?

Build a throwaway benchmark with map sizes from small to one million entries.
Apply fixed edit counts for insertions, removals, data changes, and mixed edits.

Measure key comparisons and wall time for:

- symmetric diff on shared ancestry
- symmetric diff on independently rebuilt maps
- full ordered merge as a linear control
- the complete keyed operator with unchanged child work
- downstream diff of the updated output map

Use comparison counts as the deterministic asymptotic gate. Use wall time as
supporting evidence only.

Decide the exact public complexity statement, its variables, and its
non-guarantees. The gate must distinguish fixed-change logarithmic growth from
linear map scans.

Keep the benchmark on a throwaway branch. Link its command, raw result, and
commit from the answer.

## Answer

### Decision

Use key-comparison counts as the deterministic asymptotic gate. Use child-visit
counts to gate keyed child work. Wall time is supporting evidence only.

The future Eta Signal bridge must provide affected-child notification. A keyed
implementation that scans all retained children does not satisfy the selected
change-proportional bound.

This ticket specifies an implementation requirement. It does not implement the
`eta_signal_map` and `eta_signal` bridge.

### Variables

- `n` is the larger input-map cardinality.
- `k` is the number of persistent input edits from one common ancestor.
- `d` is the number of emitted input diff events.
- `c` is the number of child outputs published without an input-map event.
- `p` is the number of persistent output-map edits.

Several edits can collapse before stabilization. Therefore, `d` and `p` can be
smaller than `k`.

### Public complexity statement

For snapshots produced by `k` persistent edits from one common ancestor,
`fold_symmetric_diff` uses:

```text
O(min(n, k log (n + 1)))
```

This bound counts key comparisons. Maps rebuilt independently remain correct,
but their diff can use `O(n)` comparisons. Serialization and conversion sever
the required ancestry.

With affected-child notification, keyed reconciliation overhead is:

```text
O(min(n, k log (n + 1)) + (d + c) log (n + 1))
```

Scanning all retained children adds `O(n)` work. Such an implementation must
state a linear bound and must not publish the optimized bound.

Downstream diff between the old output and an output made by `p` persistent
patches uses:

```text
O(min(n, p log (n + 1)))
```

Builder, cutoff, child computation, cleanup, and user callback costs are
additional. The statement makes no wall-time, allocation, memory, or
constant-factor guarantee. It treats one key comparison as one unit.

### Executable gate

Run insertion, removal, data-change, and mixed workloads at sizes 31, 127,
1,023, 16,383, 262,143, and 1,000,000. Use edit counts 1, 8, and 64 where the
map is large enough.

The deterministic ceilings are:

- `8 * k * (ceil(log2(n + 1)) + 1)` comparisons for shared and downstream diff
- `16 * k * (ceil(log2(n + 1)) + 1)` comparisons for affected-child
  reconciliation

Independent diff and full ordered merge must use at least `n - k` comparisons.
A full-scan keyed control must visit at least `n - k` children. At large sizes,
shared and downstream diff must use less than one quarter of the linear control.

These constants are regression budgets. They are not public complexity
constants.

The production implementation must run the same gate against its real map and
dirty-child path before it publishes the selected bound.

### Evidence

The final prototype is commit `4247ebcd` on branch
`prototype/eta-signal-map-benchmark`. Run it with:

```sh
bash .scratch/prototypes/eta-signal-map-benchmark/run.sh all
```

The command passes on OxCaml `5.2.0+ox` and mainline OCaml `5.4.1`. Each track
produces 512 rows. The Eta comparison, event, child-visit, and output-patch
counts agree across the two tracks.

At one million entries and 64 edits:

- shared diff uses 893 to 964 comparisons
- independent diff uses 1,000,000 to 1,000,128 comparisons
- full ordered merge uses 1,000,000 to 1,000,064 comparisons
- affected-child reconciliation uses 893 to 2,241 comparisons and at most 64
  child visits
- full-scan reconciliation visits 999,936 to 1,000,064 children
- downstream diff uses 893 to 964 comparisons

Raw results are in `results/oxcaml.csv` and `results/mainline.csv` below the
prototype directory. `results/SUMMARY.md` contains the one-million-entry table.

### Jane Street Base comparison

The benchmark also runs Base `Map.fold_symmetric_diff` through its public API
with the same maps, edits, comparator counter, and physical `data_equal`.

The OxCaml track uses Base `v0.18~preview.130.91+190`. Its benchmarked map paths
are unchanged from the reviewed Base source at
`4e3b745fb95d66fa0e13601d7fa7aeaed7962043`. The mainline track uses Base
`v0.17.2` as secondary evidence.

At one million entries and 64 edits, Eta uses 893 to 964 shared-diff
comparisons. The OxCaml Base oracle uses 896 to 993. Mainline Base uses 896 to
987. The independent paths are linear in all three cases.

At eight edits, Eta uses 133 to 142 comparisons. Base uses 133 to 147. At one
data edit, Base uses one comparison while Eta uses 19. That edit is Base's root
but only the immediate key successor of Eta's root.

The shared-ancestry comparison counts are at parity. Base is faster on the
linear independent path despite nearly identical comparison counts. Wall time
does not gate this decision.

This comparison covers only the map substrate. Base does not provide a keyed
signal operator. Jane Street's separate `Incr_map` package consumes Base
symmetric diff, but this prototype does not benchmark `Incr_map` child work.

The user disabled new review agents. Validation therefore used direct
self-review, shell checks, and both compiler tracks.
