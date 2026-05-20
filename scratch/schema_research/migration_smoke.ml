open Effet
open Schema_research

let run_effect_env env eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env () in
  Runtime.run rt eff

let run_effect eff = run_effect_env (object end) eff

let expect_ok name = function
  | Exit.Ok value -> value
  | Exit.Error (Cause.Fail (`Decode issues)) ->
      failwith (name ^ ": " ^ Fixture.render_issues issues)
  | Exit.Error (Cause.Interrupt _) -> failwith (name ^ ": interrupted")
  | Exit.Error (Cause.Die die) ->
      failwith (name ^ ": " ^ Printexc.to_string die.exn)
  | Exit.Error (Cause.Sequential _) -> failwith (name ^ ": sequential")
  | Exit.Error (Cause.Concurrent _) -> failwith (name ^ ": concurrent")
  | Exit.Error (Cause.Suppressed _) -> failwith (name ^ ": suppressed")

let expect_many_issues name min_count = function
  | Exit.Ok _ -> failwith (name ^ ": expected decode failure")
  | Exit.Error (Cause.Fail (`Decode issues)) ->
      if List.length issues < min_count then
        failwith
          (Printf.sprintf "%s: expected at least %d issues, got %d: %s" name
             min_count (List.length issues) (Fixture.render_issues issues))
  | Exit.Error _ -> failwith (name ^ ": expected typed decode failure")

let test_m_a () =
  let module A = M_a_pure_schema_effect_policy in
  let config =
    run_effect (A.Schema.decode A.config Migration_fixture.sample_config_json)
    |> expect_ok "m_a config"
  in
  if not (Migration_fixture.config_equal Migration_fixture.sample_config config) then
    failwith "m_a config equal";
  Fixture.check_json "m_a config encode" Migration_fixture.sample_config_json
    (A.Schema.encode A.config config);
  let event =
    run_effect (A.Schema.decode A.event Migration_fixture.sample_event_json)
    |> expect_ok "m_a event"
  in
  if not (Migration_fixture.event_equal Migration_fixture.sample_event event) then
    failwith "m_a event";
  let menu =
    run_effect (A.Schema.decode (A.menu ()) Migration_fixture.sample_menu_json)
    |> expect_ok "m_a menu"
  in
  if not (Migration_fixture.menu_equal Migration_fixture.sample_menu menu) then
    failwith "m_a menu";
  run_effect (A.Schema.decode A.config Migration_fixture.bad_config_many_issues_json)
  |> expect_many_issues "m_a all errors" 6;
  let env = object method feature_allowed key = String.equal key "flag.new-checkout" end in
  let _ =
    run_effect_env env (A.decode_config_with_policy Migration_fixture.sample_config_json)
    |> expect_ok "m_a policy"
  in
  ()

let test_m_b () =
  let module B = M_b_env_codec_record in
  let config =
    run_effect (B.Codec.decode (B.config ()) Migration_fixture.sample_config_json)
    |> expect_ok "m_b config"
  in
  if not (Migration_fixture.config_equal Migration_fixture.sample_config config) then
    failwith "m_b config equal";
  let env = object method feature_allowed _ = true end in
  let _ =
    run_effect_env env
      (B.Codec.decode (B.config_with_policy ()) Migration_fixture.sample_config_json)
    |> expect_ok "m_b policy"
  in
  ()

let test_m_c () =
  let module C = M_c_module_first in
  let config =
    run_effect (C.Config.decode Migration_fixture.sample_config_json)
    |> expect_ok "m_c config"
  in
  if not (C.Config.equal Migration_fixture.sample_config config) then
    failwith "m_c config equal";
  let event =
    run_effect (C.Event.decode Migration_fixture.sample_event_json)
    |> expect_ok "m_c event"
  in
  if not (C.Event.equal Migration_fixture.sample_event event) then
    failwith "m_c event";
  let menu =
    run_effect (C.Menu.decode Migration_fixture.sample_menu_json)
    |> expect_ok "m_c menu"
  in
  if not (C.Menu.equal Migration_fixture.sample_menu menu) then
    failwith "m_c menu";
  ()

let () =
  test_m_a ();
  test_m_b ();
  test_m_c ();
  Printf.printf "migration support counts: m_a=%d m_b=%d m_c=%d\n"
    (Migration_fixture.count_support M_a_pure_schema_effect_policy.support)
    (Migration_fixture.count_support M_b_env_codec_record.support)
    (Migration_fixture.count_support M_c_module_first.support)
