open Ppx_env_research

let check_string label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s expected %S got %S" label expected actual)

let check_lines label expected actual =
  if expected <> actual then
    failwith (Printf.sprintf "%s expected different log lines" label)

let () =
  let user, lines = P_a_baseline_raw.run () in
  check_string "raw user" "alice" user;
  check_lines "raw log" [ "user=alice" ] lines;

  let user, lines = P_b_leaf_ppx.run () in
  check_string "ppx leaf user" "alice" user;
  check_lines "ppx leaf log" [ "user=alice" ] lines;

  check_string "profile user" "alice" (P_c_capability_profile.run ());

  let user, lines = P_d_env_builder.run () in
  check_string "env builder user" "alice" user;
  check_lines "env builder log" [ "user=alice" ] lines

