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
    | Stdlib.Error _ -> Alcotest.fail ("expected Ok: " ^ label)

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

  let chunk_string value = [ Bytes.of_string value ]

  let body_of_fixture name =
    H.Body.Stream.of_bytes (chunk_string (read_fixture name))

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
          (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<ai-error>"))
          cause

  let test_credential_and_headers () =
    let cred = M.credential "ms-secret-key" in
    let raw = M.credential_to_string cred in
    require_contains "type" ~needle:"api_key" raw;
    require_contains "key" ~needle:"ms-secret-key" raw;
    let diag = Format.asprintf "%a" M.pp_credential cred in
    require_absent "redacted" ~needle:"ms-secret-key" diag;
    let headers = M.auth_headers cred in
    Alcotest.(check (option string))
      "auth" (Some "Bearer ms-secret-key")
      (H.Core.Header.get "authorization" headers);
    let provider = M.provider () in
    Alcotest.(check string) "base" M.default_base_url provider.base_url;
    Alcotest.(check string) "path" "/chat/completions" provider.chat_path

  let test_catalog_decode () =
    let models =
      M.decode_models (read_fixture "models.json") |> expect_ok "models"
    in
    match models with
    | [ m ] ->
        Alcotest.(check string) "id" "kimi-k2.5" m.id;
        Alcotest.(check (option int)) "ctx" (Some 262144) m.context_length
    | _ -> Alcotest.fail "expected one model"

  let test_chat_request_and_effect () =
    with_runtime @@ fun rt ->
    let captured = ref None in
    let client = test_client (response_of_fixture "chat.json") captured in
    let cred = M.credential "ms-secret-key" in
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
    let response =
      run_ok rt "chat"
        (M.chat_completions client ~credential:cred
           {
             model = "kimi-k2.5";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             max_output_tokens = None;
             replay_items = [];
             stream = false;
           })
    in
    (match response.message with
    | A.Assistant { content = A.Text text :: _; _ } ->
        Alcotest.(check string) "text" "moonshot hello" text
    | _ -> Alcotest.fail "assistant");
    let models =
      run_ok rt "models"
        (M.list_models
           (test_client (response_of_fixture "models.json") (ref None))
           ~credential:cred)
    in
    Alcotest.(check int) "model count" 1 (List.length models)

  let tests =
    [
      ( "moonshot",
        [
          Alcotest.test_case "credential headers" `Quick
            test_credential_and_headers;
          Alcotest.test_case "catalog decode" `Quick test_catalog_decode;
          Alcotest.test_case "chat request and effect" `Quick
            test_chat_request_and_effect;
        ] );
    ]
end
