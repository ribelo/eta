module A = Eta_ai
module C = Eta_ai_openai_codex
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

  let request_body_string (request : H.Request.t) =
    match request.body with
    | H.Request.Fixed chunks ->
        chunks |> List.map Bytes.to_string |> String.concat ""
    | H.Request.Empty -> ""
    | _ -> Alcotest.fail "expected fixed request body"

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

  let identity =
    C.client_identity ~originator:"eta-test"
      ~user_agent:"eta-test (linux 1.0; x86_64)" ()

  let entropy n = String.make n '\042'

  let test_pkce_requires_caller_entropy () =
    let verifier =
      C.code_verifier_of_entropy (entropy 32) |> expect_ok "verifier"
    in
    let state = C.state_of_entropy (entropy 16) |> expect_ok "state" in
    let plan =
      C.plan_authorize ~state ~code_verifier:verifier ~originator:"eta-test" ()
      |> expect_ok "plan"
    in
    require_contains "authorize"
      ~needle:"https://auth.openai.com/oauth/authorize" plan.authorize_url;
    let err = C.code_verifier_of_entropy (entropy 8) |> expect_error "short" in
    require_absent "no secret" ~needle:"********"
      (A.project_ai_error err).diagnostic;
    let callback =
      C.parse_authorization_callback ~expected_state:state
        (C.Callback_url
           ("http://localhost:1455/auth/callback?code=auth-code&state=" ^ state))
      |> expect_ok "callback"
    in
    Alcotest.(check string) "code" "auth-code" callback.code;
    let mismatch =
      C.parse_authorization_callback ~expected_state:state
        (C.Callback_code { code = "x"; state = Some "other" })
      |> expect_error "state mismatch"
    in
    require_contains "mismatch" ~needle:"state mismatch"
      (A.project_ai_error mismatch).diagnostic

  let test_credential_roundtrip_and_no_raw_secrets () =
    let cred =
      C.oauth_credential ~access_token:"access-secret-token"
        ~refresh_token:"refresh-secret-token" ~expires_at_ms:123L
        ~account_id:"acc_test" ()
      |> expect_ok "cred"
    in
    let raw = C.credential_to_string cred in
    require_contains "type" ~needle:"\"type\":\"oauth\"" raw;
    let decoded = C.credential_of_string raw |> expect_ok "decode" in
    Alcotest.(check string) "account" "acc_test" decoded.account_id;
    let diag = Format.asprintf "%a" C.pp_credential decoded in
    require_absent "access" ~needle:"access-secret-token" diag;
    require_absent "refresh" ~needle:"refresh-secret-token" diag;
    let bad =
      C.credential_of_string
        "{\"type\":\"oauth\",\"access_token\":\"access-secret-token\",\"refresh_token\":\"refresh-secret-token\"}"
      |> expect_error "missing account"
    in
    (match bad with
    | A.Decode_error { raw = None; _ } | A.Provider_error { raw = None; _ } ->
        ()
    | A.Decode_error { raw = Some leaked; _ }
    | A.Provider_error { raw = Some leaked; _ } ->
        Alcotest.fail ("credential error retained raw: " ^ leaked)
    | _ -> ());
    require_absent "no leak" ~needle:"access-secret-token"
      (A.project_ai_error bad).diagnostic;
    let legacy =
      C.credential_of_string "\"access-secret-token\"" |> expect_error "legacy"
    in
    require_absent "legacy no leak" ~needle:"access-secret-token"
      (A.project_ai_error legacy).diagnostic

  let test_token_requires_account_and_headers () =
    let token =
      C.decode_token_response (read_fixture "token.json") |> expect_ok "token"
    in
    Alcotest.(check string) "account" "acc_test" token.account_id;
    let missing =
      C.decode_token_response (read_fixture "token_no_account.json")
      |> expect_error "no account"
    in
    require_contains "account required" ~needle:"chatgpt_account_id"
      (A.project_ai_error missing).diagnostic;
    let cred = C.credential_of_token_set ~now_ms:1000L token in
    let headers =
      C.auth_headers_of_credential ~identity ~session_id:"sess1" ~stream:true
        cred
    in
    Alcotest.(check (option string))
      "auth" (Some "Bearer access-secret-token")
      (H.Core.Header.get "authorization" headers);
    Alcotest.(check (option string))
      "account" (Some "acc_test")
      (H.Core.Header.get "chatgpt-account-id" headers);
    Alcotest.(check (option string))
      "ua" (Some "eta-test (linux 1.0; x86_64)")
      (H.Core.Header.get "user-agent" headers);
    Alcotest.(check (option string))
      "accept" (Some "text/event-stream")
      (H.Core.Header.get "accept" headers);
    Alcotest.(check (option string))
      "session" (Some "sess1")
      (H.Core.Header.get "session-id" headers);
    let request =
      C.responses_request ~identity ~session_id:"sess1" ~credential:cred
        {
          model = "gpt-5.1-codex";
          prompt = [ A.User [ A.Text "hi" ] ];
          tools = [];
          temperature = None;
          max_output_tokens = Some 16;
          replay_items = [];
          stream = true;
        }
      |> expect_ok "responses request"
    in
    Alcotest.(check string)
      "uri" "https://chatgpt.com/backend-api/codex/responses" request.uri

  let test_models_catalog () =
    with_runtime @@ fun rt ->
    let token =
      C.decode_token_response (read_fixture "token.json") |> expect_ok "token"
    in
    let cred = C.credential_of_token_set ~now_ms:1L token in
    let models =
      run_ok rt "models"
        (C.list_models ~identity
           (test_client (response_of_fixture "models.json") (ref None))
           ~credential:cred)
    in
    match models with
    | [ m ] ->
        Alcotest.(check string) "slug" "gpt-test" m.slug;
        Alcotest.(check bool) "api" true m.supported_in_api;
        Alcotest.(check (option int)) "priority" (Some 1) m.priority;
        Alcotest.(check (option string))
          "default effort" (Some "medium") m.default_reasoning_level;
        Alcotest.(check (list string))
          "levels"
          [ "low"; "medium"; "high" ]
          m.supported_reasoning_levels
    | _ -> Alcotest.fail "one model"

  let test_exchange_effect () =
    with_runtime @@ fun rt ->
    let captured = ref None in
    let client = test_client (response_of_fixture "token.json") captured in
    let cred =
      run_ok rt "exchange"
        (C.exchange_code client ~redirect_uri:C.default_redirect_uri ~code:"c"
           ~code_verifier:"v" ~now_ms:1000L)
    in
    Alcotest.(check string) "account" "acc_test" cred.account_id;
    Alcotest.(check bool)
      "expires set" true
      (match cred.expires_at_ms with Some ms -> ms > 1000L | None -> false);
    match !captured with
    | None -> Alcotest.fail "missing request"
    | Some req ->
        Alcotest.(check string)
          "uri" "https://auth.openai.com/oauth/token" req.uri

  let test_extra_headers_and_malformed_expires () =
    let token =
      C.decode_token_response (read_fixture "token.json") |> expect_ok "token"
    in
    let cred = C.credential_of_token_set ~now_ms:1L token in
    let provider =
      C.provider_for_credential ~identity
        ~extra_headers:[ ("X-Debug", "fixture"); ("Authorization", "nope") ]
        cred
    in
    let headers = provider.auth_headers (C.access_api_key cred) in
    Alcotest.(check (option string))
      "auth wins" (Some "Bearer access-secret-token")
      (H.Core.Header.get "authorization" headers);
    Alcotest.(check (option string))
      "extra" (Some "fixture")
      (H.Core.Header.get "x-debug" headers);
    let malformed =
      C.credential_of_string
        "{\"type\":\"oauth\",\"access_token\":\"a\",\"refresh_token\":\"b\",\"account_id\":\"acc\",\"expires\":\"nope\"}"
      |> expect_error "malformed expires"
    in
    require_contains "malformed" ~needle:"malformed expires"
      (A.project_ai_error malformed).diagnostic

  let test_oauth_error_code () =
    with_runtime @@ fun rt ->
    let body =
      "{\"error\":\"invalid_grant\",\"error_description\":\"revoked\"}"
    in
    let client =
      test_client
        (H.Response.make ~status:400
           ~body:(H.Body.Stream.of_bytes [ Bytes.of_string body ])
           ())
        (ref None)
    in
    let token =
      C.decode_token_response (read_fixture "token.json") |> expect_ok "token"
    in
    let cred = C.credential_of_token_set ~now_ms:1L token in
    match B.run rt (C.refresh client cred ~now_ms:2L) with
    | Eta.Exit.Error cause ->
        let diagnostic =
          Format.asprintf "%a"
            (Eta.Cause.pp (fun fmt err ->
                 Format.pp_print_string fmt (A.project_ai_error err).diagnostic))
            cause
        in
        require_contains "invalid_grant" ~needle:"invalid_grant" diagnostic;
        require_contains "revoked" ~needle:"revoked" diagnostic
    | Eta.Exit.Ok _ -> Alcotest.fail "expected refresh failure"

  let tests =
    [
      ( "openai-codex",
        [
          Alcotest.test_case "pkce and callback validation" `Quick
            test_pkce_requires_caller_entropy;
          Alcotest.test_case "credential codecs without raw secrets" `Quick
            test_credential_roundtrip_and_no_raw_secrets;
          Alcotest.test_case "token account and headers" `Quick
            test_token_requires_account_and_headers;
          Alcotest.test_case "models catalog" `Quick test_models_catalog;
          Alcotest.test_case "exchange effect" `Quick test_exchange_effect;
          Alcotest.test_case "extra headers and malformed expires" `Quick
            test_extra_headers_and_malformed_expires;
          Alcotest.test_case "oauth error code" `Quick test_oauth_error_code;
        ] );
    ]
end
