let () =
  Printf.printf "=== P-Lbug-1 Arrow NODE Probe ===\n\n";
  let report = P_lbug_1.arrow_node_probe () in
  Printf.printf "%s\n" report;

  let before_bytes = Gc.allocated_bytes () in
  let before = Gc.quick_stat () in
  let node = P_lbug_1.decode_node_record () in
  let after = Gc.quick_stat () in
  let after_bytes = Gc.allocated_bytes () in
  Printf.printf "-- OCaml typed NODE record --\n";
  Printf.printf
    "ocaml_node={label=%s; internal_offset=%Ld; internal_table=%Ld; id=%Ld; name=%s; age=%Ld; active=%b}\n"
    node.label node.internal_offset node.internal_table node.id node.name node.age
    node.active;
  Printf.printf "ocaml_node.assertions=%s\n"
    (if String.equal node.label "Person"
        && Int64.equal node.id 7L
        && String.equal node.name "Ada"
        && Int64.equal node.age 42L
        && node.active
     then "pass"
     else "fail");
  Printf.printf "allocation.minor_words=%f\n"
    (after.Gc.minor_words -. before.Gc.minor_words);
  Printf.printf "allocation.major_words=%f\n"
    (after.Gc.major_words -. before.Gc.major_words);
  Printf.printf "allocation.promoted_words=%f\n"
    (after.Gc.promoted_words -. before.Gc.promoted_words);
  Printf.printf "allocation.allocated_bytes=%f\n"
    (after_bytes -. before_bytes);
  Printf.printf "\n=== P-Lbug-1 probe completed ===\n"
