# P-Gqa-1 Notes

Status: Complete
Verdict: Branch B, D, and E survive. Branch A survives with risk. Branch C is conditional on P-Gqa-4.

Command: nix develop -c dune exec scratch/eta_research/graph_query_api/p_gqa_1.exe
Captured log: p_gqa_1.log

Artifacts:
- p_gqa_1.ml
- p_gqa_1.log
- coverage_matrix.md

What was tested: all ten queries against Branches A-D plus surprise Branch E.

Not measured: no real LadybugDB execution; this is an OCaml call-site/rendering coverage probe.
