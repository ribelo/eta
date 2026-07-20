module A = Eta_ai
module K = Eta_ai_kimi_coding
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
    | _ -> Alcotest.fail "fixed body"

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
          (Eta.Cause.pp (fun fmt err ->
               Format.pp_print_string fmt (A.project_ai_error err).diagnostic))
          cause

  let identity =
    K.device_identity ~version:"0.0.1" ~device_id:"dev-1"
      ~device_name:"eta-test" ()

  let test_credentials_redacted () =
    let api = K.Api_key (K.api_key "kimi-api-secret") in
    let oauth =
      K.OAuth
        (K.oauth_credential ~access_token:"kimi-access-secret"
           ~refresh_token:"kimi-refresh-secret" ~expires_at:99L ())
    in
    let api_raw = K.credential_to_string api in
    let oauth_raw = K.credential_to_string oauth in
    require_contains "api type" ~needle:"api_key" api_raw;
    require_contains "oauth type" ~needle:"oauth" oauth_raw;
    let api2 = K.credential_of_string api_raw |> expect_ok "api" in
    let oauth2 = K.credential_of_string oauth_raw |> expect_ok "oauth" in
    require_absent "api diag" ~needle:"kimi-api-secret"
      (Format.asprintf "%a" K.pp_credential api2);
    require_absent "oauth diag" ~needle:"kimi-access-secret"
      (Format.asprintf "%a" K.pp_credential oauth2)

  let test_headers_and_chat_endpoint () =
    let cred = K.Api_key (K.api_key "kimi-api-secret") in
    let headers = K.auth_headers ~identity cred in
    Alcotest.(check (option string))
      "auth" (Some "Bearer kimi-api-secret")
      (H.Core.Header.get "authorization" headers);
    Alcotest.(check (option string))
      "platform" (Some "kimi_code_cli")
      (H.Core.Header.get "x-msh-platform" headers);
    Alcotest.(check (option string))
      "device" (Some "dev-1")
      (H.Core.Header.get "x-msh-device-id" headers);
    let request =
      K.chat_completions_request ~identity ~credential:cred
        {
          model = "kimi-for-coding";
          prompt = [ A.User [ A.Text "hi" ] ];
          tools = [];
          temperature = None;
          max_output_tokens = None;
          replay_items = [];
          stream = false;
        }
      |> expect_ok "chat req"
    in
    Alcotest.(check string)
      "uri" "https://api.kimi.com/coding/v1/chat/completions" request.uri

  let test_device_oauth_requests () =
    let auth_req = K.device_authorization_request ~identity () in
    Alcotest.(check string)
      "auth uri" "https://auth.kimi.com/api/oauth/device_authorization"
      auth_req.uri;
    require_contains "client"
      ~needle:("client_id=" ^ K.client_id)
      (request_body_string auth_req);
    let poll_req =
      K.device_token_poll_request ~identity ~device_code:"device-secret-code" ()
    in
    Alcotest.(check string)
      "poll uri" "https://auth.kimi.com/api/oauth/token" poll_req.uri;
    require_contains "device grant"
      ~needle:
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
      (request_body_string poll_req);
    let refresh_req =
      K.refresh_request ~identity ~refresh_token:"kimi-refresh-secret" ()
    in
    require_contains "refresh" ~needle:"grant_type=refresh_token"
      (request_body_string refresh_req)

  let test_device_oauth_outcomes () =
    with_runtime @@ fun rt ->
    let auth =
      run_ok rt "device auth"
        (K.request_device_authorization ~identity
           (test_client (response_of_fixture "device_auth.json") (ref None)))
    in
    Alcotest.(check string) "user" "ABCD-EFGH" auth.user_code;
    let pending =
      run_ok rt "pending"
        (K.poll_device_token ~identity
           (test_client
              (response_of_fixture ~status:400 "device_pending.json")
              (ref None))
           ~device_code:"device-secret-code")
    in
    (match pending with
    | K.Pending { error_code = "authorization_pending"; _ } -> ()
    | _ -> Alcotest.fail "expected pending");
    let authorized =
      run_ok rt "authorized"
        (K.poll_device_token ~identity
           (test_client (response_of_fixture "token.json") (ref None))
           ~device_code:"device-secret-code")
    in
    (match authorized with
    | K.Authorized oauth ->
        Alcotest.(check string)
          "access" "kimi-access-secret"
          (Eta_redacted.value oauth.access_token)
    | _ -> Alcotest.fail "expected authorized");
    let refreshed =
      run_ok rt "refresh"
        (K.refresh ~identity
           (test_client (response_of_fixture "token.json") (ref None))
           ~refresh_token:"kimi-refresh-secret")
    in
    Alcotest.(check string)
      "refresh access" "kimi-access-secret"
      (Eta_redacted.value refreshed.access_token)

  let test_catalog_protocol () =
    let models =
      K.decode_models (read_fixture "models.json") |> expect_ok "models"
    in
    Alcotest.(check int) "count" 2 (List.length models);
    let anthropic =
      List.find_opt (fun (m : K.model_info) -> m.id = "kimi-claude") models
    in
    (match anthropic with
    | Some { protocol = Some K.Anthropic; _ } -> ()
    | _ -> Alcotest.fail "expected anthropic protocol");
    let kimi =
      List.find_opt (fun (m : K.model_info) -> m.id = "kimi-for-coding") models
    in
    match kimi with
    | Some { protocol = None; _ } -> ()
    | Some { protocol = Some K.Kimi; _ } -> ()
    | _ -> Alcotest.fail "expected kimi default protocol absent or kimi"

  let test_messages_route () =
    with_runtime @@ fun rt ->
    let cred = K.Api_key (K.api_key "kimi-api-secret") in
    let provider = K.messages_provider ~identity () in
    Alcotest.(check string) "path" K.default_messages_path provider.chat_path;
    Alcotest.(check string) "base" K.default_base_url provider.base_url;
    let headers = provider.auth_headers (A.api_key "kimi-api-secret") in
    Alcotest.(check (option string))
      "bearer" (Some "Bearer kimi-api-secret")
      (H.Core.Header.get "authorization" headers);
    Alcotest.(check (option string))
      "no x-api-key" None
      (H.Core.Header.get "x-api-key" headers);
    Alcotest.(check (option string))
      "device" (Some "dev-1")
      (H.Core.Header.get "x-msh-device-id" headers);
    let request =
      K.messages_request ~identity ~credential:cred
        {
          model = "kimi-claude";
          prompt = [ A.User [ A.Text "hi" ] ];
          tools = [];
          temperature = None;
          max_output_tokens = Some 32;
          replay_items = [];
          stream = false;
        }
      |> expect_ok "messages request"
    in
    Alcotest.(check string)
      "uri" "https://api.kimi.com/coding/v1/messages?beta=true" request.uri;
    require_contains "anthropic body" ~needle:"\"messages\":"
      (request_body_string request);
    let captured = ref None in
    let client = test_client (response_of_fixture "message.json") captured in
    let response =
      run_ok rt "messages"
        (K.messages ~identity client ~credential:cred
           {
             model = "kimi-claude";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             max_output_tokens = Some 32;
             replay_items = [];
             stream = false;
           })
    in
    (match response.message with
    | A.Assistant { content = A.Text text :: _; _ } ->
        Alcotest.(check string) "text" "Sunny and 21C" text
    | _ -> Alcotest.fail "assistant text");
    match !captured with
    | None -> Alcotest.fail "missing request"
    | Some req ->
        Alcotest.(check (option string))
          "auth" (Some "Bearer kimi-api-secret")
          (H.Core.Header.get "authorization" req.headers);
        Alcotest.(check (option string))
          "device header" (Some "dev-1")
          (H.Core.Header.get "x-msh-device-id" req.headers)

  let test_messages_stream_projection () =
    with_runtime @@ fun rt ->
    let captured = ref None in
    let client = test_client (response_of_fixture "stream_tool.sse") captured in
    let cred = K.Api_key (K.api_key "kimi-api-secret") in
    let stream =
      run_ok rt "stream messages"
        (K.stream_messages ~identity client ~credential:cred
           {
             model = "kimi-claude";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             max_output_tokens = Some 32;
             replay_items = [];
             stream = true;
           })
    in
    let events = run_ok rt "read stream" (A.read_stream_events stream) in
    let has_text =
      List.exists
        (function A.Stream_content_delta _ -> true | _ -> false)
        events
    in
    let has_tool =
      List.exists
        (function A.Stream_tool_call_delta _ -> true | _ -> false)
        events
    in
    Alcotest.(check bool) "text delta" true has_text;
    Alcotest.(check bool) "tool events" true has_tool;
    match !captured with
    | None -> Alcotest.fail "missing stream request"
    | Some req ->
        Alcotest.(check string)
          "stream uri" "https://api.kimi.com/coding/v1/messages?beta=true"
          req.uri

  let test_chat_effect () =
    with_runtime @@ fun rt ->
    let captured = ref None in
    let client = test_client (response_of_fixture "chat.json") captured in
    let cred = K.Api_key (K.api_key "kimi-api-secret") in
    let response =
      run_ok rt "chat"
        (K.chat_completions ~identity client ~credential:cred
           {
             model = "kimi-for-coding";
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
        Alcotest.(check string) "text" "kimi hello" text
    | _ -> Alcotest.fail "assistant");
    match !captured with
    | None -> Alcotest.fail "no request"
    | Some req ->
        Alcotest.(check (option string))
          "device header" (Some "dev-1")
          (H.Core.Header.get "x-msh-device-id" req.headers)

  let tests =
    [
      ( "kimi-coding",
        [
          Alcotest.test_case "credentials redacted" `Quick
            test_credentials_redacted;
          Alcotest.test_case "headers and chat endpoint" `Quick
            test_headers_and_chat_endpoint;
          Alcotest.test_case "device oauth requests" `Quick
            test_device_oauth_requests;
          Alcotest.test_case "device oauth outcomes" `Quick
            test_device_oauth_outcomes;
          Alcotest.test_case "catalog protocol" `Quick test_catalog_protocol;
          Alcotest.test_case "chat effect" `Quick test_chat_effect;
          Alcotest.test_case "messages route" `Quick test_messages_route;
          Alcotest.test_case "messages stream projection" `Quick
            test_messages_stream_projection;
        ] );
    ]
end
