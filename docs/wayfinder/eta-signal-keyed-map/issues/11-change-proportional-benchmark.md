# Change-proportional benchmark

Type: prototype
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
