open Eta_ai

let transport_provider =
  {
    name = "stream-fixture";
    base_url = "https://stream.example";
    chat_path = "/chat";
    embeddings_path = None;
    auth_headers = (fun _ -> []);
    capabilities =
      {
        streaming = true;
        tools = true;
        tool_choice = false;
        structured_outputs = false;
        text = true;
        image_input = false;
        audio_input = false;
        video_input = false;
        embeddings = false;
        image_generation = false;
        speech = false;
        transcription = false;
        rerank = false;
        video_generation = false;
      };
    encode_chat = (fun _ -> Ok "{}");
    decode_chat =
      (fun _ ->
        Ok
          {
            id = None;
            model = None;
            message = Assistant { content = []; tool_calls = [] };
            finish_reasons = [];
            usage = None;
            raw = None;
          });
    encode_embeddings =
      (fun _ ->
        Error
          (Unsupported { provider = "stream-fixture"; feature = "embeddings" }));
    decode_embeddings =
      (fun _ ->
        Error
          (Unsupported { provider = "stream-fixture"; feature = "embeddings" }));
    decode_stream_event = (fun _ -> Ok []);
    decode_error =
      (fun ~status ~headers:_ raw ->
        Provider_error
          {
            provider = "stream-fixture";
            status = Some status;
            code = None;
            message = "error";
            raw = Some raw;
          });
  }

let test_transport_caps_error_body_before_provider_decode () =
  let decode_called = Atomic.make false in
  let provider =
    {
      transport_provider with
      decode_error =
        (fun ~status ~headers:_ raw ->
          Atomic.set decode_called true;
          Provider_error
            {
              provider = "stream-fixture";
              status = Some status;
              code = None;
              message = "provider decoded oversized error";
              raw = Some raw;
            });
    }
  in
  let error_body = String.make 32 'x' in
  let net = Eio_mock.Net.make "eta-ai-error-body-cap-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-ai-error-body-cap-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return
        (Printf.sprintf
           "HTTP/1.1 500 Internal Server Error\r\nContent-Length: %d\r\n\r\n%s"
           (String.length error_body) error_body);
    ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let client = Eta_http_eio.Client.make_h1 ~sw ~net () in
  let request = Eta_http.Request.make "GET" "http://api.example.test/fail" in
  match Eta.Runtime.run rt (perform_raw ~max_bytes:8 provider client request) with
  | Eta.Exit.Error (Eta.Cause.Fail (Eta_http_error error)) -> (
      match error.Eta_http.Error.kind with
      | Eta_http.Error.Body_too_large { limit; length } ->
          Alcotest.(check int) "limit" 8 limit;
          Alcotest.(check bool) "reported overflow" true (length > limit);
          Alcotest.(check bool) "decode_error not called" false
            (Atomic.get decode_called)
      | _ ->
          Alcotest.failf "expected Body_too_large, got %a" Eta_http.Error.pp
            error)
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Eta_http_error, got %a"
        (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected oversized error body failure"

let () =
  Alcotest.run "eta-ai-eio-transport"
    [
      ( "provider-transport",
        [
          Alcotest.test_case "error body max bytes before decode" `Quick
            test_transport_caps_error_body_before_provider_decode;
        ] );
    ]
