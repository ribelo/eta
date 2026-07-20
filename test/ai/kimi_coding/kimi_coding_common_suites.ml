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
    | _ -> Alcotest.fail "fixed body"

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

  let run_error rt label eff =
    match B.run rt eff with
    | Eta.Exit.Error cause -> cause
    | Eta.Exit.Ok _ -> Alcotest.fail ("expected error: " ^ label)

  let chat_request ?reasoning () : A.chat_request =
    {
      model = "kimi-for-coding";
      prompt = [ A.User [ A.Text "hi" ] ];
      tools = [];
      temperature = None;
      reasoning;
      max_output_tokens = Some 32;
      replay_items = [];
      stream = false;
    }

  let identity =
    K.device_identity ~product:"eta-test" ~version:"0.0.1" ~device_id:"dev-1"
      ~device_name:"eta-test" ()
    |> expect_ok "identity"

  let test_identity_requires_product () =
    let err =
      K.device_identity ~product:"" ~version:"1" ()
      |> expect_error "empty product"
    in
    require_contains "product" ~needle:"product"
      (A.project_ai_error err).diagnostic

  let test_credentials_strict_safe () =
    let api =
      K.api_key "kimi-api-secret" |> expect_ok "api" |> fun k -> K.Api_key k
    in
    let oauth =
      K.oauth_credential ~access_token:"kimi-access-secret"
        ~refresh_token:"kimi-refresh-secret" ~expires_at:99L ()
      |> expect_ok "oauth"
      |> fun o -> K.OAuth o
    in
    let api_raw = K.credential_to_string api in
    let oauth_raw = K.credential_to_string oauth in
    require_contains "api type" ~needle:"\"type\":\"api_key\"" api_raw;
    require_contains "oauth type" ~needle:"\"type\":\"oauth\"" oauth_raw;
    require_absent "api diag" ~needle:"kimi-api-secret"
      (Format.asprintf "%a" K.pp_credential api);
    require_absent "oauth diag" ~needle:"kimi-access-secret"
      (Format.asprintf "%a" K.pp_credential oauth);
    let bad =
      K.credential_of_string
        "{\"type\":\"oauth\",\"access_token\":\"kimi-access-secret\",\"refresh_token\":\"kimi-refresh-secret\"}"
      |> expect_error "missing expires"
    in
    (match bad with
    | A.Decode_error { raw = None; _ } | A.Provider_error { raw = None; _ } ->
        ()
    | A.Decode_error { raw = Some leaked; _ }
    | A.Provider_error { raw = Some leaked; _ } ->
        Alcotest.fail ("raw retained: " ^ leaked)
    | _ -> ());
    let legacy =
      K.credential_of_string "\"kimi-api-secret\"" |> expect_error "legacy"
    in
    require_absent "legacy" ~needle:"kimi-api-secret"
      (A.project_ai_error legacy).diagnostic

  let test_device_oauth_outcomes () =
    with_runtime @@ fun rt ->
    let auth =
      run_ok rt "device auth"
        (K.request_device_authorization ~identity
           (test_client (response_of_fixture "device_auth.json") (ref None)))
    in
    Alcotest.(check string) "user" "ABCD-EFGH" auth.user_code;
    require_contains "url" ~needle:"https://" auth.verification_uri;
    let missing_url =
      K.decode_device_authorization
        (read_fixture "device_auth_missing_url.json")
      |> expect_error "missing url"
    in
    require_contains "verification" ~needle:"verification"
      (A.project_ai_error missing_url).diagnostic;
    let pending =
      run_ok rt "pending"
        (K.poll_device_token ~identity ~now_s:10L ~current_interval:5
           (test_client
              (response_of_fixture ~status:400 "device_pending.json")
              (ref None))
           ~device_code:auth.device_code)
    in
    (match pending with
    | K.Authorization_pending _ -> ()
    | _ -> Alcotest.fail "expected pending");
    let authorized =
      run_ok rt "authorized"
        (K.poll_device_token ~identity ~now_s:1000L
           (test_client (response_of_fixture "token.json") (ref None))
           ~device_code:auth.device_code)
    in
    (match authorized with
    | K.Authorized oauth ->
        Alcotest.(check bool) "expires preserved" true (oauth.expires_at > 1000L);
        require_absent "device code diag" ~needle:"device-secret-code"
          (Format.asprintf "%a" K.pp_credential (K.OAuth oauth))
    | _ -> Alcotest.fail "expected authorized");
    let unknown =
      K.decode_device_poll ~status:400 ~now_s:1L
        "{\"error\":\"invalid_grant\",\"error_description\":\"nope\"}"
      |> expect_error "unknown"
    in
    require_contains "invalid" ~needle:"invalid_grant"
      (A.project_ai_error unknown).diagnostic;
    let server =
      K.decode_device_poll ~status:503 ~now_s:1L "{}" |> expect_error "5xx"
    in
    (match server with
    | A.Provider_error { status = Some 503; raw = None; _ } -> ()
    | _ -> Alcotest.fail "expected provider 503");
    let refreshed =
      run_ok rt "refresh"
        (K.refresh ~identity ~now_s:2000L
           (test_client (response_of_fixture "token.json") (ref None))
           (match authorized with
           | K.Authorized oauth -> oauth
           | _ -> Alcotest.fail "oauth"))
    in
    Alcotest.(check bool) "refresh expires" true (refreshed.expires_at > 2000L)

  let test_messages_headers_and_stream () =
    with_runtime @@ fun rt ->
    let cred =
      K.api_key "kimi-api-secret" |> expect_ok "api" |> fun k -> K.Api_key k
    in
    let captured = ref None in
    let request =
      K.messages_request ~identity ~credential:cred
        {
          model = "kimi-claude";
          prompt = [ A.User [ A.Text "hi" ] ];
          tools = [];
          temperature = None;
          reasoning = None;
          max_output_tokens = Some 32;
          replay_items = [];
          stream = false;
        }
      |> expect_ok "messages request"
    in
    Alcotest.(check string)
      "uri" "https://api.kimi.com/coding/v1/messages?beta=true" request.uri;
    Alcotest.(check (option string))
      "auth" (Some "Bearer kimi-api-secret")
      (H.Core.Header.get "authorization" request.headers);
    Alcotest.(check (option string))
      "anthropic-version" (Some "2023-06-01")
      (H.Core.Header.get "anthropic-version" request.headers);
    Alcotest.(check (option string))
      "device" (Some "dev-1")
      (H.Core.Header.get "x-msh-device-id" request.headers);
    Alcotest.(check (option string))
      "no x-api-key" None
      (H.Core.Header.get "x-api-key" request.headers);
    let response =
      run_ok rt "messages"
        (K.messages ~identity
           (test_client (response_of_fixture "message.json") captured)
           ~credential:cred
           {
             model = "kimi-claude";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             reasoning = None;
             max_output_tokens = Some 32;
             replay_items = [];
             stream = false;
           })
    in
    (match response.message with
    | A.Assistant { content = A.Text text :: _; _ } ->
        Alcotest.(check string) "text" "Sunny and 21C" text
    | _ -> Alcotest.fail "assistant");
    let stream =
      run_ok rt "stream messages"
        (K.stream_messages ~identity
           (test_client (response_of_fixture "stream_tool.sse") (ref None))
           ~credential:cred
           {
             model = "kimi-claude";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             reasoning = None;
             max_output_tokens = Some 32;
             replay_items = [];
             stream = true;
           })
    in
    let events =
      run_ok rt "read messages stream" (A.read_stream_events stream)
    in
    let has_text =
      List.exists
        (function A.Stream_content_delta _ -> true | _ -> false)
        events
    in
    Alcotest.(check bool) "stream text" true has_text

  let test_catalog_and_chat_reasoning () =
    with_runtime @@ fun rt ->
    let models =
      K.decode_models (read_fixture "models.json") |> expect_ok "models"
    in
    Alcotest.(check int) "count" 2 (List.length models);
    let anthropic =
      List.find (fun (m : K.model_info) -> m.id = "kimi-claude") models
    in
    (match anthropic.protocol with
    | Some K.Anthropic -> ()
    | _ -> Alcotest.fail "protocol");
    (match anthropic.supports_thinking_type with
    | Some K.Both -> ()
    | _ -> Alcotest.fail "thinking");
    let cred =
      K.api_key "kimi-api-secret" |> expect_ok "api" |> fun k -> K.Api_key k
    in
    let stream =
      run_ok rt "chat stream"
        (K.stream_chat_completions ~identity
           (test_client (response_of_fixture "stream_reasoning.sse") (ref None))
           ~credential:cred
           {
             model = "kimi-for-coding";
             prompt = [ A.User [ A.Text "hi" ] ];
             tools = [];
             temperature = None;
             reasoning = None;
             max_output_tokens = None;
             replay_items = [];
             stream = true;
           })
    in
    let events = run_ok rt "read" (A.read_stream_events stream) in
    let has_reasoning =
      List.exists
        (function A.Stream_reasoning_delta "plan" -> true | _ -> false)
        events
    in
    Alcotest.(check bool) "reasoning" true has_reasoning

  let test_reasoning_levels () =
    let credential =
      K.api_key "kimi-api-secret" |> expect_ok "api" |> fun key ->
      K.Api_key key
    in
    let cases =
      [ None; Some "off"; Some "minimal"; Some "low"; Some "medium";
        Some "high"; Some "xhigh"; Some "max" ]
    in
    let parse raw =
      match A.Json.parse raw with
      | Stdlib.Ok json -> json
      | Stdlib.Error message -> Alcotest.fail message
    in
    List.iter
      (fun reasoning ->
        let chat =
          K.chat_completions_request ~identity ~credential
            (chat_request ?reasoning ())
          |> expect_ok "chat reasoning request" |> request_body_string |> parse
        in
        let chat_thinking =
          A.Json.member "thinking" chat |> Option.map A.Json.compact
        in
        let expected_chat =
          Option.map
            (fun level ->
              if String.equal level "off" then {|{"type":"disabled"}|}
              else {|{"type":"enabled"}|})
            reasoning
        in
        Alcotest.(check (option string))
          "chat thinking" expected_chat chat_thinking;
        List.iter
          (fun name ->
            Alcotest.(check (option string))
              ("chat no " ^ name) None
              (A.Json.member name chat |> Option.map A.Json.compact))
          [ "reasoning"; "reasoning_effort"; "output_config" ];
        let messages =
          K.encode_messages (chat_request ?reasoning ())
          |> expect_ok "messages reasoning" |> parse
        in
        let member name =
          A.Json.member name messages |> Option.map A.Json.compact
        in
        let expected_thinking, expected_output =
          match reasoning with
          | None -> (None, None)
          | Some "off" -> (Some {|{"type":"disabled"}|}, None)
          | Some ("minimal" | "low") ->
              (Some {|{"type":"adaptive"}|}, Some {|{"effort":"low"}|})
          | Some "medium" ->
              (Some {|{"type":"adaptive"}|}, Some {|{"effort":"medium"}|})
          | Some "high" ->
              (Some {|{"type":"adaptive"}|}, Some {|{"effort":"high"}|})
          | Some "xhigh" ->
              (Some {|{"type":"adaptive"}|}, Some {|{"effort":"xhigh"}|})
          | Some "max" ->
              (Some {|{"type":"adaptive"}|}, Some {|{"effort":"max"}|})
          | Some _ -> assert false
        in
        Alcotest.(check (option string))
          "messages thinking" expected_thinking (member "thinking");
        Alcotest.(check (option string))
          "messages output config" expected_output (member "output_config"))
      cases;
    List.iter
      (fun reasoning ->
        (match
           K.chat_completions_request ~identity ~credential
             (chat_request ~reasoning ())
         with
        | Stdlib.Error (A.Unsupported { provider = "kimi-coding"; _ }) -> ()
        | _ -> Alcotest.fail "expected invalid chat reasoning error");
        match K.encode_messages (chat_request ~reasoning ()) with
        | Stdlib.Error (A.Unsupported { provider = "kimi-coding"; _ }) -> ()
        | _ -> Alcotest.fail "expected invalid messages reasoning error")
      [ ""; " "; "unknown" ];
    let provider = K.messages_provider ~identity () in
    match provider.encode_chat (chat_request ~reasoning:"unknown" ()) with
    | Stdlib.Error (A.Unsupported { provider = "kimi-coding"; _ }) -> ()
    | _ -> Alcotest.fail "expected Kimi provider attribution"

  let test_protocol_and_poll_errors () =
    with_runtime @@ fun rt ->
    let unknown =
      K.decode_models
        "{\"data\":[{\"id\":\"x\",\"context_length\":1,\"protocol\":\"nope\"}]}"
      |> expect_error "unknown protocol"
    in
    require_contains "proto" ~needle:"unknown model protocol"
      (A.project_ai_error unknown).diagnostic;
    let wrong_type =
      K.decode_models
        "{\"data\":[{\"id\":\"x\",\"context_length\":1,\"protocol\":42}]}"
      |> expect_error "non-string protocol"
    in
    require_contains "protocol type" ~needle:"must be a string"
      (A.project_ai_error wrong_type).diagnostic;
    let non_json_5xx =
      K.decode_device_poll ~status:503 ~now_s:1L "not-json"
      |> expect_error "5xx"
    in
    (match non_json_5xx with
    | A.Provider_error { status = Some 503; raw = None; _ } -> ()
    | _ -> Alcotest.fail "expected 503 provider error");
    let unknown_4xx =
      K.decode_device_poll ~status:400 ~now_s:1L
        "{\"error\":\"invalid_grant\",\"error_description\":\"gone\"}"
      |> expect_error "4xx"
    in
    (match unknown_4xx with
    | A.Provider_error
        {
          status = Some 400;
          code = Some "invalid_grant";
          message;
          raw = None;
          _;
        } ->
        require_contains "gone" ~needle:"gone" message
    | _ -> Alcotest.fail "expected invalid_grant provider error");
    let cred =
      K.api_key "kimi-api-secret" |> expect_ok "api" |> fun k -> K.Api_key k
    in
    let provider =
      K.provider ~identity
        ~extra_headers:[ ("X-Debug", "fixture"); ("Authorization", "nope") ]
        ()
    in
    let headers = provider.auth_headers (K.access_api_key cred) in
    Alcotest.(check (option string))
      "auth wins" (Some "Bearer kimi-api-secret")
      (H.Core.Header.get "authorization" headers);
    Alcotest.(check (option string))
      "ua" (Some "eta-test/0.0.1")
      (H.Core.Header.get "user-agent" headers);
    Alcotest.(check (option string))
      "extra" (Some "fixture")
      (H.Core.Header.get "x-debug" headers)

  let tests =
    [
      ( "kimi-coding",
        [
          Alcotest.test_case "credentials strict safe" `Quick
            test_credentials_strict_safe;
          Alcotest.test_case "device oauth outcomes" `Quick
            test_device_oauth_outcomes;
          Alcotest.test_case "messages headers and stream" `Quick
            test_messages_headers_and_stream;
          Alcotest.test_case "catalog and chat reasoning" `Quick
            test_catalog_and_chat_reasoning;
          Alcotest.test_case "reasoning levels" `Quick test_reasoning_levels;
          Alcotest.test_case "identity requires product" `Quick
            test_identity_requires_product;
          Alcotest.test_case "protocol and poll errors" `Quick
            test_protocol_and_poll_errors;
        ] );
    ]
end
