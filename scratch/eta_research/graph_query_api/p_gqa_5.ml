let cases =
  [
    ("return_node", "RETURN p",
     [("tuple","Clean","Person.t");
      ("record","Awkward","{ p : Person.t } generated");
      ("hlist","Awkward","Person.t h1")]);
    ("return_two_strings", "RETURN a.name, b.name",
     [("tuple","Clean","string * string");
      ("record","Clean","{ a_name : string; b_name : string }");
      ("hlist","Awkward","string @ string @ nil")]);
    ("return_node_count", "RETURN p, count(*) AS n",
     [("tuple","Clean","Person.t * int64");
      ("record","Clean","{ p : Person.t; n : int64 }");
      ("hlist","Awkward","Person.t @ int64 @ nil")]);
  ]

let () =
  print_endline "=== P-Gqa-5 Heterogeneous Result Decoder ===";
  List.iter
    (fun (name, cypher, options) ->
      Printf.printf "\ncase=%s cypher=%s\n" name cypher;
      List.iter
        (fun (shape, verdict, ty) ->
          Printf.printf "%s.%s=%s type=%s\n" name shape verdict ty)
        options)
    cases;
  print_endline "\nverdict=Tuple decoder is the smallest primary shape; generated records are useful optional sugar when aliases matter; hlist/applicative shape is too ceremonial for the three tested queries.";
  print_endline "surprise=Generated records help most for multi-column scalar returns, not for RETURN p.";
