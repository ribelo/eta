let check_int label expected actual =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected %d got %d" label expected actual)

let check_lines label expected actual =
  if expected <> actual then failwith (label ^ ": unexpected log lines")

let check_missing_log_is_runtime () =
  let db = Handled_effect_r_channel.Services.make_db "main" in
  try
    ignore
      (Handled_effect_r_channel.Handled_combined.run_db_only ~db (fun h ->
         Handled_effect_r_channel.Handled_combined.a h "42"));
    failwith "combined db-only handler unexpectedly succeeded"
  with
  | Failure msg when String.equal msg "missing log provider" -> ()

let () =
  let db = Handled_effect_r_channel.Services.make_db "main" in
  let log = Handled_effect_r_channel.Services.make_log () in
  check_int
    "env row"
    46
    (Handled_effect_r_channel.Env_row_baseline.boot ~db ~log "42");
  check_lines
    "env row log"
    [ "fetching 42" ]
    (Handled_effect_r_channel.Services.lines log);
  let db = Handled_effect_r_channel.Services.make_db "main" in
  let log = Handled_effect_r_channel.Services.make_log () in
  check_int
    "handled combined"
    46
    (Handled_effect_r_channel.Handled_combined.run ~db ~log (fun h ->
       Handled_effect_r_channel.Handled_combined.a h "42"));
  check_lines
    "handled combined log"
    [ "fetching 42" ]
    (Handled_effect_r_channel.Services.lines log);
  check_missing_log_is_runtime ();
  let db = Handled_effect_r_channel.Services.make_db "main" in
  let log = Handled_effect_r_channel.Services.make_log () in
  check_int
    "handled separate"
    46
    (Handled_effect_r_channel.Handled_separate.run ~db ~log (fun db_h log_h ->
       Handled_effect_r_channel.Handled_separate.a db_h log_h "42"));
  check_lines
    "handled separate log"
    [ "fetching 42" ]
    (Handled_effect_r_channel.Services.lines log);
  Printf.printf "handled_effect R-channel smoke passed\n%!"
