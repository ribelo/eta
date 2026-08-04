# Core work economics

Type: prototype
Status: open
Blocked by: none

## Question

What deterministic graph work does the current engine perform for F1, N4, and
F13 workloads?

Add throwaway counters for node visits, edge checks, registry scans, observer
root scans, dependency searches, bind candidates, necessity work, and timer
work. Measure quiescent stabilization, a narrow source change, a half-graph
change, a nested bind switch, a keyed child-only change, and wide `all`
construction and invalidation.

Use several graph sizes to distinguish constant, linear, and quadratic work.
Record wall time only as supporting evidence. Link the prototype and results as
assets.
