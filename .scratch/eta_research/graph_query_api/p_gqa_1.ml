open Graph_query_api_lab

let () =
  Printf.printf "=== P-Gqa-1 Coverage Probe ===\n\n";
  Printf.printf "Candidates: %d\n" (List.length candidates);
  Printf.printf "Queries: %d\n\n" (List.length queries);

  List.iter
    (fun c ->
      Printf.printf "## Branch %s - %s\n" c.name c.description;
      List.iter
        (fun q ->
          let _, verdict, call, why = cell c q.id in
          Printf.printf "%s %s: %s\n" q.id q.title (verdict_to_string verdict);
          Printf.printf "  call: %s\n" call;
          Printf.printf "  why: %s\n" why)
        queries;
      Printf.printf "  clean=%d awkward=%d escape=%d fails=%d status=%s\n\n"
        (count (function Clean -> true | _ -> false) c)
        (count (function Awkward -> true | _ -> false) c)
        (count (function Escape_hatch -> true | _ -> false) c)
        (count (function Fails -> true | _ -> false) c)
        (candidate_status c))
    candidates;

  Printf.printf "=== Matrix Rows ===\n";
  List.iter
    (fun c ->
      List.iter (fun q -> print_cell q.id c) queries)
    candidates;

  Printf.printf "\nverdict=Branch B, D, and E survive P-Gqa-1; Branch A is weaker but not eliminated; Branch C remains conditional on P-Gqa-4 feasibility.\n";
  Printf.printf "surprise=Branch E emerged: typed reusable pattern fragments plus literal clauses is often cleaner than a fully-general pipe builder.\n"
