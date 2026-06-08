# P-Gqa-4 Notes

Status: Partial
Verdict: literal PPX is viable as parameter/schema lint only. Return-shape inference is Untested because reliable inference requires a real Cypher parser or LadybugDB metadata.

Command: nix develop -c dune exec scratch/eta_research/graph_query_api/p_gqa_4.exe
Captured log: p_gqa_4.log

Artifacts:
- p_gqa_4.ml
- p_gqa_4.log

Not measured: a real PPX rewriter, full Cypher parser, compile-time negative test integration.
