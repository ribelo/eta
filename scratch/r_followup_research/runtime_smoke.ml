open R_followup_research

let check_equal label expected actual =
  if actual <> expected then
    failwith
      (Printf.sprintf "%s expected %S but got %S" label expected actual)

let check_int label expected actual =
  if actual <> expected then
    failwith
      (Printf.sprintf "%s expected %d but got %d" label expected actual)

let () =
  let result, audit = Black_box.run_black_box_uses_host_db () in
  check_equal "black-box host db"
    "before=real:before;child=real:child;after=real:after;secret=s3"
    result;
  check_equal "black-box host audit" "real:before,real:after"
    (String.concat "," audit);

  let result, audit = Black_box.run_constructor_can_swap_child_db () in
  check_equal "constructor fake child"
    "before=real:before;child=fake:child;after=real:after;secret=s3"
    result;
  check_equal "constructor audit" "real:before,real:after"
    (String.concat "," audit);

  let result, audit = Black_box.run_separate_boundary_can_swap_but_splits_program () in
  check_equal "separate boundary fake child"
    "before=real:before;child=fake:child;after=real:after;secret=s3"
    result;
  check_equal "separate boundary audit" "real:before,real:after"
    (String.concat "," audit);

  let result, audit =
    Black_box.run_private_eval_can_swap_but_reimplements_runtime_subset ()
  in
  check_equal "private eval fake child"
    "before=real:before;child=fake:child;after=real:after;secret=s3"
    result;
  check_equal "private eval audit" "real:before,real:after"
    (String.concat "," audit);

  let generic_user, generic_order = Naming_collision.run_generic_collision () in
  check_equal "generic user" "shared:current-user" generic_user;
  check_equal "generic order" "shared:current-order" generic_order;

  let namespaced_user, namespaced_order = Naming_collision.run_namespaced () in
  check_equal "namespaced user" "user:current" namespaced_user;
  check_equal "namespaced order" "order:current" namespaced_order;

  let value, count = Library_evolution.run_env_v2 () in
  check_int "env evolution value" 42 value;
  check_int "env evolution metric" 1 count;

  let value, count = Library_evolution.run_args_v2 () in
  check_int "args evolution value" 42 value;
  check_int "args evolution metric" 1 count;

  let value, count = Library_evolution.run_bag_v2 () in
  check_int "bag evolution value" 42 value;
  check_int "bag evolution metric" 1 count

