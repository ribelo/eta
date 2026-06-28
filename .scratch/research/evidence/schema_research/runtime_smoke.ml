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
  | Exit.Error cause ->
      let msg =
        match cause with
        | Cause.Fail (`Decode issues) -> Fixture.render_issues issues
        | Cause.Interrupt _ -> "interrupt"
        | Cause.Die die -> Printexc.to_string die.exn
        | Cause.Sequential _ -> "sequential"
        | Cause.Concurrent _ -> "concurrent"
        | Cause.Suppressed _ -> "suppressed"
      in
      failwith (name ^ ": expected Ok, got " ^ msg)

let expect_decode_error name = function
  | Exit.Ok _ -> failwith (name ^ ": expected decode error")
  | Exit.Error (Cause.Fail (`Decode issues)) -> issues
  | Exit.Error _ -> failwith (name ^ ": expected typed decode failure")

let test_hs0 () =
  Fixture.check_bool "h_s0 no support count"
    (Fixture.count_supported H_s0_skip.support = 0)

let test_hs1 () =
  let person =
    run_effect (H_s1_decode.decode_person Fixture.person_ok_json)
    |> expect_ok "h_s1 decode"
  in
  Fixture.check_person "h_s1 person" Fixture.person_ok person;
  let _issues =
    run_effect (H_s1_decode.decode_person Fixture.person_bad_missing)
    |> expect_decode_error "h_s1 failure"
  in
  let observed = ref false in
  let recovered =
    H_s1_decode.decode_person Fixture.person_bad_missing
    |> Effect.tap_error (function `Decode _ -> observed := true)
    |> Effect.catch (function `Decode _issues -> Effect.pure Fixture.person_ok)
    |> run_effect |> expect_ok "h_s1 catch"
  in
  Fixture.check_person "h_s1 recovered" Fixture.person_ok recovered;
  if not !observed then failwith "h_s1 cause integration";
  let env = object method age_policy age = age < 100 end in
  let person =
    run_effect_env env (H_s1_decode.decode_person_effectful Fixture.person_ok_json)
    |> expect_ok "h_s1 effectful"
  in
  Fixture.check_person "h_s1 effectful person" Fixture.person_ok person

let test_hs2 () =
  let person =
    run_effect (H_s2_decode_validate.decode_person Fixture.person_ok_json)
    |> expect_ok "h_s2 decode"
  in
  Fixture.check_person "h_s2 person" Fixture.person_ok person;
  let _issues =
    run_effect (H_s2_decode_validate.decode_person Fixture.person_bad_refinement)
    |> expect_decode_error "h_s2 refinement"
  in
  let user_id =
    run_effect (H_s2_decode_validate.User_id.decode (Fixture.Json.String "u_123"))
    |> expect_ok "h_s2 brand"
  in
  if not (String.equal "u_123" (H_s2_decode_validate.User_id.value user_id)) then
    failwith "h_s2 brand value"

let test_hs3 () =
  let module S = H_s3_schema_gadt.Schema in
  let person =
    run_effect (S.decode H_s3_schema_gadt.person Fixture.person_ok_json)
    |> expect_ok "h_s3 decode"
  in
  Fixture.check_person "h_s3 person" Fixture.person_ok person;
  Fixture.check_json "h_s3 encode" Fixture.person_ok_json
    (S.encode H_s3_schema_gadt.person Fixture.person_ok);
  let finite =
    run_effect (S.decode H_s3_schema_gadt.finite_from_string (Fixture.Json.String "1.5"))
    |> expect_ok "h_s3 transform"
  in
  if not (Float.equal finite 1.5) then failwith "h_s3 finite";
  let user_id =
    run_effect (S.decode H_s3_schema_gadt.user_id (Fixture.Json.String "u_123"))
    |> expect_ok "h_s3 brand"
  in
  if not (String.equal "u_123" (S.value user_id)) then failwith "h_s3 brand";
  let color =
    run_effect (S.decode H_s3_schema_gadt.color (Fixture.Json.String "green"))
    |> expect_ok "h_s3 union"
  in
  if not (Fixture.color_equal Fixture.Green color) then failwith "h_s3 union";
  Fixture.check_bool "h_s3 arbitrary" (S.arbitrary H_s3_schema_gadt.person <> []);
  Fixture.check_bool "h_s3 equal"
    (S.equal H_s3_schema_gadt.person Fixture.person_ok Fixture.person_ok);
  Fixture.check_bool "h_s3 json schema"
    (not (Fixture.Json.equal Fixture.Json.Null (S.json_schema H_s3_schema_gadt.person)))

let test_hs4 () =
  let module S = H_s4_ppx_schema.Schema in
  let person =
    run_effect (S.decode H_s4_ppx_schema.person_schema Fixture.person_ok_json)
    |> expect_ok "h_s4 decode"
  in
  Fixture.check_person "h_s4 person" Fixture.person_ok person;
  Fixture.check_json "h_s4 encode" Fixture.person_ok_json
    (S.encode H_s4_ppx_schema.person_schema Fixture.person_ok);
  Fixture.check_bool "h_s4 arbitrary" (S.arbitrary H_s4_ppx_schema.person_schema <> []);
  Fixture.check_bool "h_s4 equal"
    (S.equal H_s4_ppx_schema.person_schema Fixture.person_ok Fixture.person_ok);
  Fixture.check_bool "h_s4 json schema"
    (not (Fixture.Json.equal Fixture.Json.Null (S.json_schema H_s4_ppx_schema.person_schema)))

let test_hs5 () =
  let module C = H_s5_codec_record.Codec in
  let person =
    run_effect (C.decode (H_s5_codec_record.person ()) Fixture.person_ok_json)
    |> expect_ok "h_s5 decode"
  in
  Fixture.check_person "h_s5 person" Fixture.person_ok person;
  Fixture.check_json "h_s5 encode" Fixture.person_ok_json
    (C.encode (H_s5_codec_record.person ()) Fixture.person_ok);
  let env = object method age_policy age = age < 100 end in
  let _ =
    run_effect_env env
      (C.decode (H_s5_codec_record.person_with_policy ()) Fixture.person_ok_json)
    |> expect_ok "h_s5 effectful"
  in
  let user_id =
    run_effect (C.decode (H_s5_codec_record.user_id ()) (Fixture.Json.String "u_123"))
    |> expect_ok "h_s5 brand"
  in
  if not (String.equal "u_123" (H_s5_codec_record.Brand.value user_id)) then
    failwith "h_s5 brand";
  let color =
    run_effect (C.decode (H_s5_codec_record.color ()) (Fixture.Json.String "blue"))
    |> expect_ok "h_s5 union"
  in
  if not (Fixture.color_equal Fixture.Blue color) then failwith "h_s5 union";
  Fixture.check_bool "h_s5 arbitrary" (C.arbitrary (H_s5_codec_record.person ()) <> []);
  Fixture.check_bool "h_s5 equal"
    (C.equal (H_s5_codec_record.person ()) Fixture.person_ok Fixture.person_ok);
  Fixture.check_bool "h_s5 json schema"
    (Option.is_some (C.json_schema (H_s5_codec_record.person ())))

let () =
  test_hs0 ();
  test_hs1 ();
  test_hs2 ();
  test_hs3 ();
  test_hs4 ();
  test_hs5 ();
  Printf.printf
    "support counts: h0=%d h1=%d h2=%d h3=%d h4=%d h5=%d\n"
    (Fixture.count_supported H_s0_skip.support)
    (Fixture.count_supported H_s1_decode.support)
    (Fixture.count_supported H_s2_decode_validate.support)
    (Fixture.count_supported H_s3_schema_gadt.support)
    (Fixture.count_supported H_s4_ppx_schema.support)
    (Fixture.count_supported H_s5_codec_record.support)
