let assert_true name value =
  if value then Printf.printf "%s: ok\n%!" name
  else failwith (name ^ ": failed")

let () =
  assert_true "Branch A abstract effect keeps daemon private"
    (R_detach_survival.Branch_a_delete_public
     .abstract_effect_with_private_daemon_compiles ());
  assert_true "Branch B hook observes detached failure"
    (R_detach_survival.Branch_b_hook.parent_survives_and_hook_observes ());
  Printf.printf "detach survival smoke tests passed\n%!"
