# P-Gqa-1 Coverage Matrix

Captured log: p_gqa_1.log
Command: nix develop -c dune exec scratch/eta_research/graph_query_api/p_gqa_1.exe

## Summary

| Candidate | Clean | Awkward | Escape hatch | Fails | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| A - pure typed SQL-style pipe builder | 3 | 5 | 2 | 0 | Survives with risk |
| B - hybrid pattern DSL plus pipeable clauses | 8 | 2 | 0 | 0 | Survives |
| C - Cypher literal PPX | 8 | 2 | 0 | 0 | Survives only if P-Gqa-4 is feasible |
| D - parameterized string plus typed decoder | 10 | 0 | 0 | 0 | Survives baseline |
| E - named pattern fragments plus raw Cypher clauses | 8 | 2 | 0 | 0 | Surprise survivor |

## Matrix

| Query | A | B | C | D | E |
| --- | --- | --- | --- | --- | --- |
| Q1 simple lookup | Clean | Clean | Clean | Clean | Clean |
| Q2 single-hop join | Awkward | Clean | Clean | Clean | Clean |
| Q3 optional match | Awkward | Clean | Clean | Clean | Clean |
| Q4 variable-length path | Escape hatch | Clean | Awkward | Clean | Clean |
| Q5 WITH chain | Awkward | Clean | Clean | Clean | Awkward |
| Q6 aggregation | Clean | Clean | Clean | Clean | Awkward |
| Q7 list parameter | Clean | Clean | Clean | Clean | Clean |
| Q8 map parameter | Awkward | Awkward | Clean | Clean | Clean |
| Q9 bulk ingest | Escape hatch | Awkward | Awkward | Clean | Clean |
| Q10 type(r) call | Awkward | Clean | Clean | Clean | Clean |

## Verdict

Branch B, D, and E survive P-Gqa-1. Branch A is weaker but not eliminated because it has only two escape hatches. Branch C looks clean at the call site but is conditional on P-Gqa-4 proving useful validation without a real Cypher parser.

Branch E emerged during probing: typed reusable pattern fragments plus raw Cypher clauses. It is not one of the starting four, but it covers the workload with less ceremony than a fully-general builder while preserving typed decoders and common graph fragments.
