# P-Gqa-2 Pattern Features

Captured log: p_gqa_2.log
Command: nix develop -c dune exec scratch/eta_research/graph_query_api/p_gqa_2.exe

| Feature | Cypher | B hybrid pattern DSL | C literal | D baseline | E fragments |
| --- | --- | --- | --- | --- | --- |
| single edge | (a)-[r]->(b) | Clean | Clean | Clean | Clean |
| two edge | (a)-[r1]->(b)-[r2]->(c) | Clean | Clean | Clean | Clean |
| variable length | (a)-[:REL*1..6]->(b) | Clean | Clean | Clean | Clean |
| optional match | OPTIONAL MATCH (p)-[r]->(c) | Clean | Clean | Clean | Clean |
| anonymous nodes | (a)-[:REL]->() | Clean | Clean | Clean | Awkward |
| bidirectional | (a)-[r]-(b) | Clean | Clean | Clean | Awkward |
| named path | path = (a)-[*]->(b) | Clean | Clean | Clean | Clean |

Verdict: Branch B covers all pattern features cleanly because it treats patterns as graph-shaped data, not as SQL-style pipes. Branch E remains useful for named fragments but is awkward for anonymous and bidirectional one-offs.
