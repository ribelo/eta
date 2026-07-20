module A = Eta_ai
module M = Eta_ai_moonshot
module E = Eta.Effect
module H = Eta_http

module Make (B : Eta_runtime_common_tests.Runtime_backend.S) = struct
  let read_fixture name =
    let path = Filename.concat "fixtures" name in
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> really_input_string input (in_channel_length input))

  let expect_ok label = function
    | Stdlib.Ok value -> value
    | Stdlib.Error err ->
        Alcotest.failf "expected Ok: %s (%s)" label
          (A.project_ai_error err).diagnostic

  let expect_error label = function
    | Stdlib.Error err -> err
    | Stdlib.Ok _ -> Alcotest.fail ("expected Error: " ^ label)

  let contains ~needle value =
    let needle_len = String.length needle in
    let value_len = String.length value in
    let rec loop index =
      if needle_len = 0 then true
      else if index + needle_len > value_len then false
      else if String.sub value index needle_len = needle then true
      else loop (index + 1)
    in
    loop 0

  let require_contains label ~needle value =
    Alcotest.(check bool) label true (contains ~needle value)

  let require_absent label ~needle value =
    Alcotest.(check bool) label false (contains ~needle value)

  let body_of_fixture name =
    H.Body.Stream.of_bytes [ Bytes.of_string (read_fixture name) ]

  let zero_stats =
    {
      H.Client.protocol = H.Client.H1;
      active = 0;
      idle = 0;
      capacity = 0;
      opened = 0;
      released = 0;
    }

  let response_of_fixture ?(status = 200) name =
    H.Response.make ~status ~body:(body_of_fixture name) ()

  let test_client response captured =
    let request http_request =
      captured := Some http_request;
      E.pure response
    in
    H.Client.make_custom ~protocol:H.Client.H1 ~request
      ~stats:(fun () -> E.pure (Some zero_stats))
      ~shutdown:(fun () -> E.unit)

  let with_runtime f = B.with_runtime (fun _ctx rt -> f rt)

  let run_ok rt label eff =
    match B.run rt eff with
    | Eta.Exit.Ok value -> value
    | Eta.Exit.Error cause ->
        Alcotest.failf "%s failed: %a" label
          (Eta.Cause.pp (fun fmt err ->
               Format.pp_print_string fmt (A.project_ai_error err).diagnostic))
          cause

  let test_credential_strict_and_safe () =
    let cred = M.credential "ms-secret-key" |> expect_ok "cred" in
    let raw = M.credential_to_string cred in
    require_contains "type" ~needle:"\"type\":\"api_key\"" raw;
    let diag = Format.asprintf "%a" M.pp_credential cred in
    require_absent "redacted" ~needle:"ms-secret-key" diag;
    let bad =
      M.credential_of_string "{\"type\":\"api_key\"}" |> expect_error "missing"
    in
    (match bad with
    | A.Decode_error { raw = None; _ } | A.Provider_error { raw = None; _ } ->
        ()
    | A.Decode_error { raw = Some leaked; _ }
    | A.Provider_error { raw = Some leaked; _ } ->
        Alcotest.fail ("raw retained: " ^ leaked)
    | _ -> ());
    let legacy =
      M.credential_of_string "\"ms-secret-key\"" |> expect_error "legacy"
    in
    require_absent "legacy" ~needle:"ms-secret-key"
      (A.project_ai_error legacy).diagnostic;
    let headers = M.auth_headers cred in
    Alcotest.(check (option string))
      "auth" (Some "Bearer ms-secret-key")
      (H.Core.Header.get "authorization" headers)

  let test_catalog_thinking_metadata () =
    let models =
      M.decode_models (read_fixture "models.json") |> expect_ok "models"
    in
    match models with
    | [ m ] -> (
        Alcotest.(check string) "id" "kimi-k2.5" m.id;
        (match m.supports_thinking_type with
        | Some M.Both -> ()
        | _ -> Alcotest.fail "thinking type");
        match m.think_efforts with
        | Some
            {
              valid_efforts = [ "low"; "high" ];
              default_effort = Some "low";
              _;
            } ->
            ()
        | _ -> Alcotest.fail "think efforts")
    | _ -> Alcotest.fail "one model"

  let test_chat_and_reasoning_stream () =
    with_runtime @@ fun rt ->
    let cred = M.credential "ms-secret-key" |> expect_ok "cred" in
    let request =
      M.chat_completions_request ~credential:cred
        {
          model = "kimi-k2.5";
          prompt = [ A.User [ A.Text "hi" ] ];
          tools = [];
          temperature = Some 0.1;
          max_output_tokens = Some 32;
          replay_items = [];
          stream = false;
        }
      |> expect_ok "request"
    in
    Alcotest.(check string)
      "uri" "https://api.moonshot.ai/v1/chat/completions" request.uri;
    let stream =
      run_ok rt "stream"
        (M.stream_chat_completions
           (test_client (response_of_fixture "stream_reasoning.sse") (ref None))
           ~credential:cred
           {
             model = "kimi-k2.5";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             max_output_tokens = None;
             replay_items = [];
             stream = true;
           })
    in
    let events = run_ok rt "read" (A.read_stream_events stream) in
    let has_reasoning =
      List.exists
        (function A.Stream_reasoning_delta "think" -> true | _ -> false)
        events
    in
    let has_text =
      List.exists
        (function A.Stream_content_delta "hi" -> true | _ -> false)
        events
    in
    Alcotest.(check bool) "reasoning" true has_reasoning;
    Alcotest.(check bool) "text" true has_text

  let tests =
    [
      ( "moonshot",
        [
          Alcotest.test_case "credential strict safe" `Quick
            test_credential_strict_and_safe;
          Alcotest.test_case "catalog thinking metadata" `Quick
            test_catalog_thinking_metadata;
          Alcotest.test_case "chat and reasoning stream" `Quick
            test_chat_and_reasoning_stream;
        ] );
    ]
end
