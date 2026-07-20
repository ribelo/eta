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

  let request_body_string (request : H.Request.t) =
    match request.body with
    | H.Request.Fixed chunks ->
        chunks |> List.map Bytes.to_string |> String.concat ""
    | H.Request.Empty -> ""
    | H.Request.Stream _ | H.Request.Rewindable_stream _ ->
        Alcotest.fail "expected fixed request body"

  let chunk_string value =
    let sizes = [| 7; 3; 19; 2; 11 |] in
    let rec loop index size_index acc =
      if index >= String.length value then List.rev acc
      else
        let size = sizes.(size_index mod Array.length sizes) in
        let len = min size (String.length value - index) in
        loop (index + len) (size_index + 1)
          (Bytes.of_string (String.sub value index len) :: acc)
    in
    loop 0 0 []

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

  let test_pkce_and_authorize_plan () =
    let verifier = "alpha-verifier-0123456789" in
    let pkce = C.pkce_s256 ~code_verifier:verifier in
    Alcotest.(check string) "method" "S256" pkce.code_challenge_method;
    Alcotest.(check bool)
      "challenge nonempty" true
      (String.length pkce.code_challenge > 10);
    let plan =
      C.plan_authorize ~state:"state123" ~code_verifier:verifier
        ~originator:"eta-test" ()
    in
    require_contains "issuer host"
      ~needle:"https://auth.openai.com/oauth/authorize" plan.authorize_url;
    require_contains "client"
      ~needle:("client_id=" ^ C.client_id)
      plan.authorize_url;
    require_contains "challenge"
      ~needle:("code_challenge=" ^ pkce.code_challenge)
      plan.authorize_url;
    require_contains "originator" ~needle:"originator=eta-test"
      plan.authorize_url;
    require_contains "simplified" ~needle:"codex_cli_simplified_flow=true"
      plan.authorize_url;
    Alcotest.(check string) "redirect" C.default_redirect_uri plan.redirect_uri

  let test_credential_roundtrip_redacted () =
    let cred =
      C.oauth_credential ~access_token:"access-secret-token"
        ~refresh_token:"refresh-secret-token" ~expires_at_ms:123L
        ~account_id:"acc_test" ()
    in
    let raw = C.credential_to_string cred in
    require_contains "type" ~needle:"\"type\":\"oauth\"" raw;
    require_contains "access stored" ~needle:"access-secret-token" raw;
    let decoded = C.credential_of_string raw |> expect_ok "decode cred" in
    Alcotest.(check (option string))
      "account" (Some "acc_test") decoded.account_id;
    let diag = Format.asprintf "%a" C.pp_credential decoded in
    require_absent "no access in diag" ~needle:"access-secret-token" diag;
    require_absent "no refresh in diag" ~needle:"refresh-secret-token" diag;
    require_contains "redacted label" ~needle:"redacted" diag

  let test_exchange_and_refresh_requests () =
    let exchange =
      C.exchange_code_request ~redirect_uri:C.default_redirect_uri
        ~code:"auth-code" ~code_verifier:"verifier" ()
    in
    Alcotest.(check string)
      "exchange uri" "https://auth.openai.com/oauth/token" exchange.uri;
    Alcotest.(check string) "method" "POST" exchange.method_;
    let body = request_body_string exchange in
    require_contains "grant" ~needle:"grant_type=authorization_code" body;
    require_contains "code" ~needle:"code=auth-code" body;
    require_contains "verifier" ~needle:"code_verifier=verifier" body;
    let refresh = C.refresh_request ~refresh_token:"refresh-secret-token" () in
    Alcotest.(check string)
      "refresh uri" "https://auth.openai.com/oauth/token" refresh.uri;
    require_contains "refresh grant" ~needle:"grant_type=refresh_token"
      (request_body_string refresh);
    require_contains "refresh token"
      ~needle:"refresh_token=refresh-secret-token"
      (request_body_string refresh)

  let test_token_decode_account_id () =
    let token =
      C.decode_token_response (read_fixture "token.json") |> expect_ok "token"
    in
    Alcotest.(check string) "access" "access-secret-token" token.access_token;
    let cred = C.credential_of_token_set ~now_ms:1_000L token in
    Alcotest.(check (option string)) "account" (Some "acc_test") cred.account_id;
    Alcotest.(check (option int64))
      "expires" (Some 3_601_000L) cred.expires_at_ms

  let test_provider_headers_and_endpoint () =
    let provider =
      C.provider ~account_id:"acc_test" ~originator:"eta" ~session_id:"sess1" ()
    in
    Alcotest.(check string) "name" "openai-codex" provider.name;
    Alcotest.(check string) "base" C.default_base_url provider.base_url;
    Alcotest.(check string) "path" "/responses" provider.chat_path;
    let headers = provider.auth_headers (A.api_key "access-secret-token") in
    Alcotest.(check (option string))
      "auth" (Some "Bearer access-secret-token")
      (H.Core.Header.get "authorization" headers);
    Alcotest.(check (option string))
      "account" (Some "acc_test")
      (H.Core.Header.get "chatgpt-account-id" headers);
    Alcotest.(check (option string))
      "originator" (Some "eta")
      (H.Core.Header.get "originator" headers);
    Alcotest.(check (option string))
      "beta" (Some "responses=experimental")
      (H.Core.Header.get "openai-beta" headers);
    let cred =
      C.oauth_credential ~access_token:"access-secret-token"
        ~refresh_token:"refresh-secret-token" ~account_id:"acc_test" ()
    in
    let request =
      C.responses_request ~credential:cred
        {
          model = "gpt-5.1-codex";
          prompt = [ A.User [ A.Text "hi" ] ];
          tools = [];
          temperature = None;
          max_output_tokens = Some 16;
          replay_items = [];
          stream = false;
        }
      |> expect_ok "responses request"
    in
    Alcotest.(check string)
      "uri" "https://chatgpt.com/backend-api/codex/responses" request.uri

  let test_exchange_effect () =
    with_runtime @@ fun rt ->
    let captured = ref None in
    let client = test_client (response_of_fixture "token.json") captured in
    let token =
      run_ok rt "exchange"
        (C.exchange_code client ~redirect_uri:C.default_redirect_uri ~code:"c"
           ~code_verifier:"v")
    in
    Alcotest.(check string) "access" "access-secret-token" token.access_token;
    match !captured with
    | None -> Alcotest.fail "missing request"
    | Some req ->
        Alcotest.(check string)
          "uri" "https://auth.openai.com/oauth/token" req.uri

  let test_responses_effect () =
    with_runtime @@ fun rt ->
    let captured = ref None in
    let client = test_client (response_of_fixture "responses.json") captured in
    let cred =
      C.oauth_credential ~access_token:"access-secret-token"
        ~refresh_token:"refresh-secret-token" ~account_id:"acc_test" ()
    in
    let response =
      run_ok rt "responses"
        (C.responses client ~credential:cred
           {
             model = "gpt-5.1-codex";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             max_output_tokens = Some 16;
             replay_items = [];
             stream = false;
           })
    in
    (match response.message with
    | A.Assistant { content = A.Text text :: _; _ } ->
        Alcotest.(check string) "text" "hello from codex" text
    | _ -> Alcotest.fail "expected assistant text");
    match !captured with
    | None -> Alcotest.fail "missing request"
    | Some req ->
        Alcotest.(check (option string))
          "auth header" (Some "Bearer access-secret-token")
          (H.Core.Header.get "authorization" req.headers)

  let tests =
    [
      ( "openai-codex",
        [
          Alcotest.test_case "pkce and authorize plan" `Quick
            test_pkce_and_authorize_plan;
          Alcotest.test_case "credential roundtrip redacted" `Quick
            test_credential_roundtrip_redacted;
          Alcotest.test_case "exchange and refresh requests" `Quick
            test_exchange_and_refresh_requests;
          Alcotest.test_case "token decode account id" `Quick
            test_token_decode_account_id;
          Alcotest.test_case "provider headers and endpoint" `Quick
            test_provider_headers_and_endpoint;
          Alcotest.test_case "exchange effect" `Quick test_exchange_effect;
          Alcotest.test_case "responses effect" `Quick test_responses_effect;
        ] );
    ]
end
