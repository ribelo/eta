let features =
  [
    ("single_edge", "(a)-[r]->(b)",
     [("B","Clean","Pattern.(node a -- rel r --> node b)");
      ("C","Clean","literal preserves native Cypher pattern");
      ("D","Clean","raw Cypher string");
      ("E","Clean","named fragment any_edge")]);
    ("two_edge", "(a)-[r1]->(b)-[r2]->(c)",
     [("B","Clean","pattern chain composes");
      ("C","Clean","literal preserves native Cypher pattern");
      ("D","Clean","raw Cypher string");
      ("E","Clean","named fragment can compose two sub-patterns")]);
    ("variable_length", "(a)-[:REL*1..6]->(b)",
     [("B","Clean","rel REL ~hops:(1,6)");
      ("C","Clean","literal syntax is native");
      ("D","Clean","raw Cypher string");
      ("E","Clean","path_between ~hops:(1,6)")]);
    ("optional_match", "OPTIONAL MATCH (p)-[r]->(c)",
     [("B","Clean","optional Pattern.(...)");
      ("C","Clean","literal syntax is native");
      ("D","Clean","raw Cypher string");
      ("E","Clean","optional reusable fragment")]);
    ("anonymous_nodes", "(a)-[:REL]->()",
     [("B","Clean","anon_node ()");
      ("C","Clean","literal syntax is native");
      ("D","Clean","raw Cypher string");
      ("E","Awkward","fragment must expose anonymous endpoint")]);
    ("bidirectional", "(a)-[r]-(b)",
     [("B","Clean","rel r ~dir:Either");
      ("C","Clean","literal syntax is native");
      ("D","Clean","raw Cypher string");
      ("E","Awkward","requires a separate undirected fragment")]);
    ("named_path", "path = (a)-[*]->(b)",
     [("B","Clean","path name pattern");
      ("C","Clean","literal syntax is native");
      ("D","Clean","raw Cypher string");
      ("E","Clean","path fragment returns path binding")]);
  ]

let () =
  print_endline "=== P-Gqa-2 Pattern Composition Expressiveness ===";
  List.iter
    (fun (feature, cypher, rows) ->
      Printf.printf "\nfeature=%s cypher=%s\n" feature cypher;
      List.iter
        (fun (candidate, verdict, expr) ->
          Printf.printf "%s.%s=%s expr=%s\n" candidate feature verdict expr)
        rows)
    features;
  print_endline "\nverdict=Branch B covers all pattern features cleanly; Branch E is useful for named fragments but awkward for anonymous and bidirectional one-offs; Branch C/D trivially preserve Cypher syntax.";
  print_endline "surprise=Pattern composition is graph-shaped, not SQL-shaped: Branch B survives because it stops trying to make the pattern itself a pipe."
