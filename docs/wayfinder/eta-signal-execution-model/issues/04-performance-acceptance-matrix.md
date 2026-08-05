# Performance acceptance matrix

Type: grilling
Status: resolved
Blocked by: 01, 02, 03

## Question

What exact allocation, wall-time, and affected-work gates select or reject an
execution model for every workload class?

Name the reference, operation count, observation point, and graph size for each
gate. Keep correctness and affected-work complexity as eligibility conditions.

## Answer

Correctness and deterministic affected-work gates determine eligibility before
performance ranking.

Matched wall-time rows use fresh same-environment Incremental comparisons. A row
passes when the Eta median is at most `1.20` times the reference in two of three
nine-sample comparisons.

Static raw propagation must allocate fewer than 100 words, independent of
depth. Dynamic and keyed raw rows can allocate at most `1.20` times their raw
Incremental reference. Eta-only adapter and edge rows cannot exceed the pinned
pre-redesign Eta baseline.

Rank eligible candidates by module depth, then worst allocation ratio, then
worst wall-time ratio.

The complete workload matrix, exact sizes, operation counts, formulas, adapter
ceilings, and comparison protocol are in
[Performance acceptance matrix](../../../../.scratch/research/eta-signal-execution-model/performance-acceptance-matrix.md).
