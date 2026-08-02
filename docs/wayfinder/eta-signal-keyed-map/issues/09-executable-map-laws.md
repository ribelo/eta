# Executable map laws

Type: grilling
Status: claimed
Blocked by: 05, 06

## Question

Which named executable laws define `Eta_signal_map.Map`?

Specify one property or registered test for each law-bearing public claim. Cover
ordering, uniqueness, lookup after edits, persistence, ancestry preservation,
diff ordering, diff completeness, and forward and reverse reconstruction.

Also cover duplicate rejection, stable key representatives, physical no-op
identity, extensional equality without physical shortcuts, physical-only
`Changed`, and conditional ancestry retention through `map` and `filter_mapi`.

Separate semantic laws from performance observations. A semantic law must hold
for independently built maps. An ancestry-performance claim uses the benchmark
ticket instead.

For each generated property, state:

- the generated map and edit class
- the observation boundary
- the discriminating case
- the printed counterexample

Name the rewritten Base scenarios that remain fixed regression tests. Do not
copy Base test code.

Record every new `.mli` claim and named test in
`.scratch/research/dx/e22/review/LAWS.md` when implementation starts. New prose
cannot use an uncovered placeholder.
