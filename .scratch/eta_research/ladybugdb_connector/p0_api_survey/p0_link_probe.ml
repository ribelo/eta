(** P0 LadybugDB link probe — confirms liblbug is reachable and functional. *)

let () =
  Printf.printf "=== P0 LadybugDB Link Probe ===\n\n";
  Printf.printf "lbug_version=%s\n" (P0_lbug.lbug_version ());
  Printf.printf "%s\n" (P0_lbug.lbug_smoke ());
  Printf.printf "\n%s\n" (P0_lbug.lbug_api_survey ());
  Printf.printf "\n=== P0 probe completed successfully ===\n"
