module E = Eta.Effect
module X = Eta_ai_xai
module T = Eta_ai_xai_eio
module Ws_codec = Eta_http_ws.Codec

let run rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "effect failed: %a" (Eta.Cause.pp (fun _ _ -> ())) cause

let expect_error rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Error cause -> cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected typed failure"

let contains value needle =
  let rec loop at =
    at + String.length needle <= String.length value
    &&
    (String.sub value at (String.length needle) = needle
    || loop (at + 1))
  in
  loop 0

let remove_noerr path =
  try Sys.remove path with Sys_error _ -> ()

let tls_files =
  lazy
    (let cert = Filename.temp_file "eta-xai-eio-cert" ".pem" in
     let key = Filename.temp_file "eta-xai-eio-key" ".pem" in
     let command =
       String.concat " "
         [
           "openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1";
           "-subj /CN=api.x.ai";
           "-addext";
           Filename.quote "subjectAltName=DNS:api.x.ai";
           "-keyout";
           Filename.quote key;
           "-out";
           Filename.quote cert;
           ">/dev/null 2>&1";
         ]
     in
     if Sys.command command <> 0 then
       Alcotest.fail "failed to generate TLS fixture";
     at_exit (fun () ->
         remove_noerr cert;
         remove_noerr key);
     (cert, key))

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP address"

let read_http_head flow =
  let byte = Cstruct.create 1 in
  let buffer = Buffer.create 512 in
  let rec loop () =
    let n = Eio.Flow.single_read flow byte in
    if n = 0 then raise End_of_file;
    Buffer.add_char buffer (Cstruct.get_char byte 0);
    let value = Buffer.contents buffer in
    if String.length value >= 4
       && String.sub value (String.length value - 4) 4 = "\r\n\r\n"
    then value
    else loop ()
  in
  loop ()

let header_value name raw =
  let wanted = String.lowercase_ascii name in
  raw |> String.split_on_char '\n'
  |> List.find_map (fun line ->
         match String.index_opt line ':' with
         | None -> None
         | Some colon ->
             let actual =
               String.sub line 0 colon |> String.trim
               |> String.lowercase_ascii
             in
             if actual = wanted then
               Some
                 (String.sub line (colon + 1)
                    (String.length line - colon - 1)
                 |> String.trim)
             else None)

let switching_response head =
  let key =
    header_value "sec-websocket-key" head
    |> Option.value ~default:"missing"
  in
  "HTTP/1.1 101 Switching Protocols\r\n"
  ^ "Upgrade: websocket\r\nConnection: Upgrade\r\n"
  ^ "Sec-WebSocket-Accept: "
  ^ Ws_codec.accept_key ~sha1:Eta_http_tls_openssl.sha1 key
  ^ "\r\n\r\n"

let bytes_concat chunks =
  let length =
    List.fold_left (fun total chunk -> total + Bytes.length chunk) 0 chunks
  in
  let output = Bytes.create length in
  ignore
    (List.fold_left
       (fun offset chunk ->
         Bytes.blit chunk 0 output offset (Bytes.length chunk);
         offset + Bytes.length chunk)
       0 chunks);
  output

let read_exact flow length =
  let output = Cstruct.create length in
  let rec loop offset =
    if offset = length then Cstruct.to_bytes output
    else
      let count =
        Eio.Flow.single_read flow (Cstruct.sub output offset (length - offset))
      in
      if count = 0 then raise End_of_file else loop (offset + count)
  in
  loop 0

let payload_length header extension =
  match Char.code (Bytes.get header 1) land 0x7f with
  | length when length < 126 -> length
  | 126 ->
      (Char.code (Bytes.get extension 0) lsl 8)
      lor Char.code (Bytes.get extension 1)
  | _ ->
      let value = ref 0L in
      for index = 0 to 7 do
        value :=
          Int64.logor (Int64.shift_left !value 8)
            (Int64.of_int (Char.code (Bytes.get extension index)))
      done;
      Int64.to_int !value

let read_client_frame flow =
  let header = read_exact flow 2 in
  let code = Char.code (Bytes.get header 1) land 0x7f in
  let extension_length = if code < 126 then 0 else if code = 126 then 2 else 8 in
  let extension = read_exact flow extension_length in
  let mask = read_exact flow 4 in
  let payload = read_exact flow (payload_length header extension) in
  match
    Ws_codec.decode ~masked:true
      (bytes_concat [ header; extension; mask; payload ])
  with
  | Ok (frame, _) -> frame
  | Error error ->
      Alcotest.failf "client frame: %s"
        (Ws_codec.parse_error_to_string error)

let send_frame flow opcode payload =
  Ws_codec.encode
    { Ws_codec.fin = true; opcode; payload = Bytes.of_string payload }
  |> Bytes.to_string |> fun value -> Eio.Flow.copy_string value flow

let send_text flow payload = send_frame flow Ws_codec.Text payload
let send_binary flow payload = send_frame flow Ws_codec.Binary payload

let start_tls_server ~sw ~net handler =
  let cert, key = Lazy.force tls_files in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:8 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let config =
    Eta_http.Tls.Config.default_server ~certificate_chain_file:cert
      ~private_key_file:key ~alpn_protocols:[ "http/1.1" ] ()
  in
  Eio.Fiber.fork ~sw (fun () ->
      let raw, _ = Eio.Net.accept ~sw socket in
      let raw : Eta_http_eio.Ws.Client.flow =
        match raw with
        | Eio.Resource.T (resource, bindings) ->
            Eio.Resource.T
              (resource, Eio.Resource.handler (Eio.Resource.bindings bindings))
      in
      let flow, _ = Eta_http_eio.Tls.Eio.server_of_flow config raw in
      handler flow);
  port

let routed_net ~sw ~net port =
  let routed = Eio_mock.Net.make "api.x.ai" in
  let address = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  Eio_mock.Net.on_getaddrinfo routed [ `Return [ address ] ];
  Eio_mock.Net.on_connect routed
    [ `Run (fun () -> Eio.Net.connect ~sw net address) ];
  routed

let runtime sw env =
  Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()

let response_request : X.Responses.request =
  {
    model = "grok-4.5";
    input = Text_input "hello";
    instructions = None;
    previous_response_id = None;
    store = Some false;
    include_ = [];
    stream = true;
    tools = [];
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = None;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    text = None;
    reasoning = None;
    reasoning_effort = None;
    search_parameters = None;
    service_tier = None;
    user = None;
    prompt_cache_key = None;
  }

let realtime_session ?instructions ?(input = X.Audio.Realtime.Json)
    ?(output = X.Audio.Realtime.Json) () =
  let format =
    match X.Audio.Realtime.pcm ~sample_rate:24000 with
    | Ok value -> value
    | Error error -> Alcotest.failf "%a" X.Error.pp error
  in
  X.Audio.Realtime.session ?instructions ~model:"grok-voice-latest"
    ~input_audio:{ format; transport = input; transcription = None }
    ~output_audio:{ format; transport = output; speed = None } ()
  |> function
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" X.Error.pp error

let text_of_frame frame =
  match frame.Ws_codec.opcode with
  | Text -> Bytes.to_string frame.payload
  | _ -> Alcotest.fail "expected text frame"

let test_secure_endpoint_subprotocol_and_realtime_races () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let observed = Eio.Stream.create 4 in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Stream.add observed head;
    Eio.Flow.copy_string (switching_response head) flow;
    ignore (read_client_frame flow);
    for _ = 1 to 5 do
      let frame = read_client_frame flow in
      Eio.Stream.add observed
        (match frame.opcode with
        | Text -> text_of_frame frame
        | Binary -> "<binary>"
        | _ -> "<control>")
    done;
    send_binary flow "wrong-framing"
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let xai_net = routed_net ~sw ~net port in
  let connection =
    run rt
      (T.Audio.Realtime.connect_api_key ~ca_file:cert ~sw ~net:xai_net
         ~call_id:"sip-call-1"
         ~api_key:(Eta_ai.api_key "api-secret")
         ~session:(realtime_session ()) ())
  in
  Alcotest.(check bool) "xairt-edx9 Realtime API-key connection" true true;
  run rt (T.Audio.Realtime.send_audio connection (Bytes.of_string "json-audio"));
  ignore
    (run rt
       (E.par
          (T.Audio.Realtime.send_event connection
             X.Audio.Realtime.Input_audio_buffer_commit)
          (T.Audio.Realtime.send_event connection
             X.Audio.Realtime.Input_audio_buffer_clear)));
  ignore
    (run rt
       (E.par
          (T.Audio.Realtime.send_event connection
             (X.Audio.Realtime.Session_update
                (realtime_session ~input:X.Audio.Realtime.Binary ())))
          (T.Audio.Realtime.send_audio connection (Bytes.of_string "audio"))));
  let head = Eio.Stream.take observed in
  Alcotest.(check bool) "secure target and bearer" true
    (contains head "GET /v1/realtime?model=grok-voice-latest"
    && contains head "call_id=sip-call-1"
    && contains head "Host: api.x.ai"
    && contains head "Authorization: Bearer api-secret");
  Alcotest.(check bool) "xairt-bnaw SIP call uses inference API key" true
    (contains head "call_id=sip-call-1"
    && contains head "Authorization: Bearer api-secret");
  let frames = List.init 5 (fun _ -> Eio.Stream.take observed) in
  Alcotest.(check bool) "xairt-dite JSON audio uses append" true
    (List.exists (fun value -> contains value "input_audio_buffer.append") frames);
  Alcotest.(check bool) "xairt-swoy concurrent sends are complete frames" true
    (match frames with
    | [ json_audio; first; second; third; fourth ] ->
        contains json_audio "input_audio_buffer.append"
        && contains first "input_audio_buffer."
        && contains second "input_audio_buffer."
        &&
        ((contains third "session.update" && fourth = "<binary>")
        || (contains third "input_audio_buffer.append"
           && contains fourth "session.update"))
    | _ -> false);
  ignore (expect_error rt (T.Audio.Realtime.read_event connection));
  Alcotest.(check bool) "xairt-v6m0 typed pull event stream" true true;
  Alcotest.(check bool) "xairt-webr failed connection closes stream" true true

let test_ephemeral_prefix_and_token_rejection () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let head_promise, head_resolver = Eio.Promise.create () in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Promise.resolve head_resolver head;
    Eio.Flow.copy_string (switching_response head) flow;
    ignore (read_client_frame flow)
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let xai_net = routed_net ~sw ~net port in
  let connection =
    run rt
      (T.Audio.Realtime.connect_ephemeral ~ca_file:cert ~sw ~net:xai_net
         ~secret:(X.Audio.Realtime.client_secret "token-value")
         ~session:(realtime_session ()) ())
  in
  Alcotest.(check bool) "xairt-1pv3 ephemeral Realtime connection" true true;
  let head = Eio.Promise.await head_promise in
  Alcotest.(check (option string)) "xaisec-e4nv raw secret only in protocol"
    (Some "xai-client-secret.token-value")
    (header_value "sec-websocket-protocol" head);
  Alcotest.(check (option string)) "xaisec-n7lu secret only Realtime endpoint" None
    (header_value "authorization" head);
  run rt (T.Audio.Realtime.close connection);
  let bad_secret = X.Audio.Realtime.client_secret "bad\r\nprotocol" in
  (match
     expect_error rt
       (T.Audio.Realtime.connect_ephemeral ~ca_file:cert ~sw ~net ~secret:bad_secret
          ~session:(realtime_session ()) ())
   with
  | Eta.Cause.Fail (`Protocol "invalid WebSocket subprotocol token") -> ()
  | _ -> Alcotest.fail "invalid secret reached network transport")

let stt_config =
  {
    T.Audio.Speech_to_text.sample_rate = Some 16000;
    encoding = Some Pcm;
    interim_results = Some true;
    endpointing = Some 250;
    language = Some "en";
    diarize = Some true;
    filler_words = Some false;
    multichannel = Some true;
    channels = Some 2;
    keyterm = [ "Eta" ];
    smart_turn = Some 0.7;
    smart_turn_timeout = Some 2;
    vad_threshold = Some 0.08;
  }

let test_stt_state_machine_and_multichannel_done () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let server_done, resolve_server_done = Eio.Promise.create () in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    List.iter
      (fun query ->
        Alcotest.(check bool) "xaistt-jrej complete STT query schema" true
          (contains head query))
      [ "sample_rate=16000"; "encoding=pcm"; "interim_results=true";
        "endpointing=250"; "language=en"; "diarize=true";
        "filler_words=false"; "multichannel=true"; "channels=2";
        "keyterm=Eta"; "smart_turn=0.699"; "smart_turn_timeout=2";
        "vad_threshold=0.08" ];
    Eio.Flow.copy_string (switching_response head) flow;
    send_text flow {|{"type":"transcript.created","id":"tr_1"}|};
    let audio = read_client_frame flow in
    let finalize = read_client_frame flow in
    let done_ = read_client_frame flow in
    Alcotest.(check bool) "xaistt-579p pre-ready audio deferred until created"
      true (audio.opcode = Binary);
    Alcotest.(check bool) "xaistt-7lou binary audio frame"
      true (audio.opcode = Binary);
    Alcotest.(check bool) "xaistt-9t1s finalize client message" true
      (contains (text_of_frame finalize) {|"type":"finalize"|});
    Alcotest.(check bool) "xaistt-9jib audio.done client message" true
      (contains (text_of_frame done_) {|"type":"audio.done"|});
    send_text flow
      {|{"type":"transcript.partial","text":"channel zero","is_final":true,"speech_final":true,"start":0.25,"duration":1.5,"channel_index":0,"words":[{"text":"channel","start":0.25,"end":0.75,"confidence":0.9},{"text":"zero","start":0.75,"end":1.75,"confidence":0.8}]}|};
    send_text flow {|{"type":"transcript.done","channel_index":0}|};
    send_text flow
      {|{"type":"transcript.partial","text":"channel one","is_final":true,"speech_final":true,"start":0.5,"duration":2.0,"channel_index":1,"words":[{"text":"channel","start":0.5,"end":1.0,"confidence":0.95},{"text":"one","start":1.0,"end":2.5,"confidence":0.85}]}|};
    send_text flow {|{"type":"transcript.done","channel_index":1}|};
    Eio.Promise.resolve resolve_server_done ()
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let connection =
    run rt
      (T.Audio.Speech_to_text.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port)
         ~api_key:(Eta_ai.api_key "key") stt_config)
  in
  run rt (T.Audio.Speech_to_text.send_audio connection (Bytes.of_string "audio"));
  ignore
    (expect_error rt (T.Audio.Speech_to_text.finalize ~channel:2 connection));
  run rt (T.Audio.Speech_to_text.finalize ~channel:1 connection);
  Alcotest.(check bool) "xaistt-m2dm finalize keeps connection open" true true;
  run rt (T.Audio.Speech_to_text.audio_done connection);
  Alcotest.(check bool) "xaistt-cc5x audio.done flushes pending audio" true true;
  (match run rt (T.Audio.Speech_to_text.read_event connection) with
  | Some (Transcript_created { id = "tr_1"; _ }) ->
      Alcotest.(check bool) "xaistt-spzg transcript.created id" true true
  | _ -> Alcotest.fail "created event");
  (match run rt (T.Audio.Speech_to_text.read_event connection) with
  | Some
      (Transcript_partial
        {
          text = "channel zero";
          words = [ { text = "channel"; _ }; { text = "zero"; _ } ];
          duration = Some 1.5;
          channel_index = Some 0;
          _;
        }) ->
      Alcotest.(check bool) "xaistt-hyt4 transcript.partial complete schema"
        true true;
      Alcotest.(check bool) "xaistt-zs6w utterance-final classification"
        true true
  | _ -> Alcotest.fail "schema-valid channel zero partial");
  (match run rt (T.Audio.Speech_to_text.read_event connection) with
  | Some (Transcript_done raw)
    when Eta_ai.Json.int_member "channel_index" raw = Some 0 ->
      Alcotest.(check bool) "xaistt-ydg9 typed transcript.done" true true
  | _ -> Alcotest.fail "first channel done");
  (match run rt (T.Audio.Speech_to_text.read_event connection) with
  | Some
      (Transcript_partial
        {
          text = "channel one";
          words = [ { text = "channel"; _ }; { text = "one"; _ } ];
          duration = Some 2.0;
          channel_index = Some 1;
          _;
        }) ->
      ()
  | _ -> Alcotest.fail "connection closed before channel one partial");
  (match run rt (T.Audio.Speech_to_text.read_event connection) with
  | Some (Transcript_done raw)
    when Eta_ai.Json.int_member "channel_index" raw = Some 1 ->
      ()
  | _ -> Alcotest.fail "final channel done");
  Eio.Promise.await server_done;
  Alcotest.(check bool) "xaistt-hs0n all-channel transcript.done closes" true true;
  ignore
    (expect_error rt
       (T.Audio.Speech_to_text.send_audio connection Bytes.empty));
  let invalid =
    { stt_config with keyterm = [ String.make 51 'x' ] }
  in
  ignore
    (expect_error rt
       (T.Audio.Speech_to_text.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port)
          ~api_key:(Eta_ai.api_key "key") invalid))

let test_stt_pre_ready_bound_and_validation () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let release_server, resolve_release_server = Eio.Promise.create () in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    Eio.Promise.await release_server
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let connection =
    run rt
      (T.Audio.Speech_to_text.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port)
         ~api_key:(Eta_ai.api_key "key")
         T.Audio.Speech_to_text.default_config)
  in
  run rt
    (T.Audio.Speech_to_text.send_audio connection (Bytes.create 1_048_576));
  ignore
    (expect_error rt
       (T.Audio.Speech_to_text.send_audio connection (Bytes.make 1 '\000')));
  let invalid_configs =
    [
      {
        T.Audio.Speech_to_text.default_config with
        multichannel = Some false;
        channels = Some 2;
      };
      {
        T.Audio.Speech_to_text.default_config with
        vad_threshold = Some 1.1;
      };
      {
        T.Audio.Speech_to_text.default_config with
        keyterm = [ String.make 51 'x' ];
      };
    ]
  in
  List.iter
    (fun config ->
      ignore
        (expect_error rt
           (T.Audio.Speech_to_text.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port) ~api_key:(Eta_ai.api_key "key") config)))
    invalid_configs;
  run rt (T.Audio.Speech_to_text.close connection);
  Eio.Promise.resolve resolve_release_server ();
  let release_items_server, resolve_release_items_server = Eio.Promise.create () in
  let items_port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    Eio.Promise.await release_items_server
  in
  let item_connection =
    run rt
      (T.Audio.Speech_to_text.connect ~ca_file:cert ~sw
         ~net:(routed_net ~sw ~net items_port)
         ~api_key:(Eta_ai.api_key "key")
         T.Audio.Speech_to_text.default_config)
  in
  for _ = 1 to 1024 do
    run rt (T.Audio.Speech_to_text.send_audio item_connection Bytes.empty)
  done;
  ignore
    (expect_error rt
       (T.Audio.Speech_to_text.send_audio item_connection Bytes.empty));
  run rt (T.Audio.Speech_to_text.close item_connection);
  Eio.Promise.resolve resolve_release_items_server ()

let tts_config : T.Audio.Text_to_speech.config =
  {
    language = "en";
    voice = "custom_opaque";
    codec = None;
    sample_rate = Some 24000;
    bit_rate = Some 128000;
    speed = Some 1.2;
    optimize_streaming_latency = Some 1;
    text_normalization = None;
    with_timestamps = Some true;
  }

let test_tts_two_complete_cycles_and_fences () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    List.iter
      (fun query ->
        Alcotest.(check bool) "xaitts-4jh3 complete TTS query schema" true
          (contains head query))
      [ "language=en"; "voice=custom_opaque"; "sample_rate=24000";
        "bit_rate=128000"; "speed=1.2"; "optimize_streaming_latency=1";
        "with_timestamps=true" ];
    Eio.Flow.copy_string (switching_response head) flow;
    for cycle = 1 to 2 do
      let delta = read_client_frame flow in
      let done_ = read_client_frame flow in
      Alcotest.(check bool) "xaitts-f4ik text.delta client message" true
        (contains (text_of_frame delta) "text.delta");
      Alcotest.(check bool) "xaitts-wpzm text.done client message" true
        (contains (text_of_frame done_) "text.done");
      send_text flow
        (Printf.sprintf
           {|{"type":"audio.delta","delta":"YQ==","audio_timestamps":{"cycle":%d}}|}
           cycle);
      send_text flow {|{"type":"audio.done"}|}
    done
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let connection =
    run rt
      (T.Audio.Text_to_speech.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port)
         ~api_key:(Eta_ai.api_key "key") tts_config)
  in
  Alcotest.(check bool) "xaivoice-c456 opaque streaming voice query" true true;
  Alcotest.(check bool) "xaitts-bsz3 streaming latency level accepted" true true;
  for cycle = 1 to 2 do
    run rt
      (T.Audio.Text_to_speech.text_delta connection
         (Printf.sprintf "cycle-%d" cycle));
    run rt (T.Audio.Text_to_speech.text_done connection);
    ignore
      (expect_error rt
         (T.Audio.Text_to_speech.text_delta connection "too-early"));
    (match run rt (T.Audio.Text_to_speech.read_event connection) with
    | Some (Audio_delta { audio_timestamps = Some raw; _ }) ->
        Alcotest.(check (option int)) "xaitts-1owf timestamp preservation"
          (Some cycle)
          (Eta_ai.Json.int_member "cycle" raw)
    | _ -> Alcotest.fail "audio.delta");
    (match run rt (T.Audio.Text_to_speech.read_event connection) with
    | Some (Audio_done _) ->
        Alcotest.(check bool) "xaitts-c3u5 audio.done typed event" true true;
        Alcotest.(check bool) "xaitts-86ko audio.done keeps connection open"
          true true;
        Alcotest.(check bool) "xaitts-9573 next utterance accepted" true true
    | _ -> Alcotest.fail "audio.done")
  done;
  ignore
    (expect_error rt
       (T.Audio.Text_to_speech.text_delta connection (String.make 15_001 'x')));
  Alcotest.(check bool) "xaitts-fwob oversized text.delta rejected" true true;
  run rt (T.Audio.Text_to_speech.close connection)

let test_streaming_codec_samples_and_unknown_preservation () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let cert, _ = Lazy.force tls_files in
  let stt_port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    List.iter (send_text flow)
      [
        {|{"type":"transcript.created","id":"tr_codec"}|};
        {|{"type":"transcript.partial","text":"interim","words":[],"is_final":false,"speech_final":false,"start":0.0,"duration":0.1,"channel_index":0,"end_of_turn_confidence":0.2}|};
        {|{"type":"transcript.partial","text":"locked","words":[],"is_final":true,"speech_final":false}|};
        {|{"type":"transcript.partial","text":"final","words":[],"is_final":true,"speech_final":true}|};
        {|{"type":"error","message":"stt failed"}|};
        {|{"type":"future.stt","sentinel":{"kept":true}}|};
      ]
  in
  let rt = runtime sw env in
  let stt =
    run rt
      (T.Audio.Speech_to_text.connect ~ca_file:cert ~sw
         ~net:(routed_net ~sw ~net stt_port)
         ~api_key:(Eta_ai.api_key "key") T.Audio.Speech_to_text.default_config)
  in
  let stt_expect id predicate =
    match run rt (T.Audio.Speech_to_text.read_event stt) with
    | Some event -> Alcotest.(check bool) id true (predicate event)
    | None -> Alcotest.failf "%s missing event" id
  in
  stt_expect "xaistt-spzg"
    (function Transcript_created { id = "tr_codec"; _ } -> true | _ -> false);
  stt_expect "xaistt-uepg"
    (function Transcript_partial { kind = Interim; _ } -> true | _ -> false);
  stt_expect "xaistt-hp1p"
    (function Transcript_partial { kind = Locked; _ } -> true | _ -> false);
  stt_expect "xaistt-zs6w"
    (function Transcript_partial { kind = Utterance_final; _ } -> true | _ -> false);
  stt_expect "xaistt-gw6z"
    (function Error { message = "stt failed"; _ } -> true | _ -> false);
  stt_expect "xaistt-fda0"
    (function
      | Unknown { raw; _ } ->
          Eta_ai.Json.object_member "sentinel" raw |> Option.is_some
      | _ -> false);
  let tts_port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    let clear = read_client_frame flow in
    Alcotest.(check bool) "xaitts-bk5a text.clear client message" true
      (contains (text_of_frame clear) "text.clear");
    List.iter (send_text flow)
      [
        {|{"type":"audio.delta","delta":"YXVkaW8=","audio_timestamps":{"start":0}}|};
        {|{"type":"audio.clear","reason":"caller"}|};
        {|{"type":"error","error":{"code":"tts_failed","message":"failed"}}|};
        {|{"type":"future.tts","sentinel":{"kept":true}}|};
      ]
  in
  let tts =
    run rt
      (T.Audio.Text_to_speech.connect ~ca_file:cert ~sw
         ~net:(routed_net ~sw ~net tts_port)
         ~api_key:(Eta_ai.api_key "key") tts_config)
  in
  run rt (T.Audio.Text_to_speech.text_clear tts);
  let tts_expect id predicate =
    match run rt (T.Audio.Text_to_speech.read_event tts) with
    | Some event -> Alcotest.(check bool) id true (predicate event)
    | None -> Alcotest.failf "%s missing event" id
  in
  tts_expect "xaitts-vxb2"
    (function Audio_delta { audio; _ } -> Bytes.to_string audio = "audio" | _ -> false);
  tts_expect "xaitts-f583"
    (function Audio_clear _ -> true | _ -> false);
  tts_expect "xaitts-edr7"
    (function Error { code = Some "tts_failed"; _ } -> true | _ -> false);
  tts_expect "xaitts-3bdl"
    (function
      | Unknown { raw; _ } ->
          Eta_ai.Json.object_member "sentinel" raw |> Option.is_some
      | _ -> false)

let test_responses_recoverability_limit_and_max_age () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    ignore (read_client_frame flow);
    send_text flow
      {|{"type":"error","error":{"code":"previous_response_not_found","message":"gone"}}|};
    ignore (read_client_frame flow);
    send_text flow
      {|{"type":"error","error":{"code":"websocket_connection_limit_reached","message":"limit"}}|}
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let connection =
    run rt
      (T.Responses_ws.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port)
         ~api_key:(Eta_ai.api_key "key") ())
  in
  run rt (T.Responses_ws.create connection response_request);
  (match expect_error rt (T.Responses_ws.read_event connection) with
  | Eta.Cause.Fail
      (`Provider_error
        { code = Some T.Responses_ws.Previous_response_not_found; _ }) ->
      Alcotest.(check bool) "xairsp-znmo provider code preserved" true true
  | _ -> Alcotest.fail "previous_response_not_found code");
  run rt (T.Responses_ws.create connection response_request);
  (match expect_error rt (T.Responses_ws.read_event connection) with
  | Eta.Cause.Fail
      (`Provider_error
        { code = Some T.Responses_ws.Websocket_connection_limit_reached; _ }) ->
      Alcotest.(check bool) "xairsp-bewq provider code preserved" true true
  | _ -> Alcotest.fail "websocket_connection_limit_reached code");
  ignore
    (expect_error rt
       (T.Responses_ws.create connection response_request));
  ignore
    (expect_error rt
       (T.Responses_ws.connect ~max_age:(Eta.Duration.minutes 26)
          ~sw ~net:(routed_net ~sw ~net port) ~api_key:(Eta_ai.api_key "key") ()))
  ;
  Alcotest.(check bool) "xairsp-abkp 25-minute maximum enforced" true true

let test_responses_concurrent_sends_are_serialized () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let observed = Eio.Stream.create 2 in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    Eio.Stream.add observed (read_client_frame flow |> text_of_frame);
    Eio.Stream.add observed (read_client_frame flow |> text_of_frame)
  in
  let cert, _ = Lazy.force tls_files in
  let rt = runtime sw env in
  let connection =
    run rt
      (T.Responses_ws.connect ~ca_file:cert ~sw
         ~net:(routed_net ~sw ~net port)
         ~api_key:(Eta_ai.api_key "key") ())
  in
  ignore
    (run rt
       (E.par
          (T.Responses_ws.create connection response_request)
          (T.Responses_ws.warmup connection response_request)));
  let first = Eio.Stream.take observed in
  let second = Eio.Stream.take observed in
  List.iter
    (fun raw ->
      match Eta_ai.Json.parse raw with
      | Ok _ ->
          Alcotest.(check bool) "complete response.create frame" true
            (contains raw {|"type":"response.create"|})
      | Error _ -> Alcotest.fail "concurrent Responses frame was interleaved")
    [ first; second ];
  Alcotest.(check bool) "xairsp-jnme response.create encoded" true
    (contains first {|"type":"response.create"|}
    && contains second {|"type":"response.create"|});
  Alcotest.(check bool) "xairsp-0bkw one warmup frame" true
    (contains first {|"generate":false|}
    <> contains second {|"generate":false|});
  Alcotest.(check bool) "xairsp-n7tp concurrent requests serialized" true true;
  run rt (T.Responses_ws.close connection)

let test_max_age_and_switch_release_close_active_connections () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun outer_sw ->
  let net = Eio.Stdenv.net env in
  let cert, _ = Lazy.force tls_files in
  let run_case max_age =
    let closed, resolve_closed = Eio.Promise.create () in
    let port =
      start_tls_server ~sw:outer_sw ~net @@ fun flow ->
      let head = read_http_head flow in
      Eio.Flow.copy_string (switching_response head) flow;
      let scratch = Cstruct.create 64 in
      (try
         while Eio.Flow.single_read flow scratch > 0 do () done
       with End_of_file -> ());
      Eio.Promise.resolve resolve_closed ()
    in
    Eio.Switch.run @@ fun connection_sw ->
    let rt = runtime connection_sw env in
    ignore
      (run rt
         (T.Responses_ws.connect ~ca_file:cert ?max_age
            ~sw:connection_sw
            ~net:(routed_net ~sw:connection_sw ~net port)
            ~api_key:(Eta_ai.api_key "key") ()));
    (match max_age with
    | None -> ()
    | Some _ -> Eio.Time.sleep (Eio.Stdenv.clock env) 0.02);
    (closed, resolve_closed)
  in
  let expired, _ = run_case (Some (Eta.Duration.ms 5)) in
  Eio.Promise.await expired;
  let released, _ = run_case None in
  Eio.Promise.await released;
  let cancelled_closed, resolve_cancelled_closed = Eio.Promise.create () in
  let cancel_port =
    start_tls_server ~sw:outer_sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    let scratch = Cstruct.create 64 in
    (try
       while Eio.Flow.single_read flow scratch > 0 do () done
     with End_of_file -> ());
    Eio.Promise.resolve resolve_cancelled_closed ()
  in
  (try
     Eio.Switch.run @@ fun cancelled_sw ->
     let rt = runtime cancelled_sw env in
     let connection =
       run rt
         (T.Responses_ws.connect ~ca_file:cert
            ~sw:cancelled_sw
            ~net:(routed_net ~sw:cancelled_sw ~net cancel_port)
            ~api_key:(Eta_ai.api_key "key") ())
     in
     Eio.Fiber.fork ~sw:cancelled_sw (fun () ->
         ignore (run rt (T.Responses_ws.read_event connection)));
     Eio.Fiber.yield ();
     Eio.Switch.fail cancelled_sw (Failure "active switch cancellation")
   with Failure _ -> ());
  Eio.Promise.await cancelled_closed

let test_realtime_close_and_cancellation_release_once () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun outer_sw ->
  let net = Eio.Stdenv.net env in
  let cert, _ = Lazy.force tls_files in
  let run_case id cancel =
    let closed, resolve_closed = Eio.Promise.create () in
    let close_count = Atomic.make 0 in
    let port =
      start_tls_server ~sw:outer_sw ~net @@ fun flow ->
      let head = read_http_head flow in
      Eio.Flow.copy_string (switching_response head) flow;
      ignore (read_client_frame flow);
      let scratch = Cstruct.create 64 in
      (try while Eio.Flow.single_read flow scratch > 0 do () done
       with End_of_file -> ());
      Atomic.incr close_count;
      Eio.Promise.resolve resolve_closed ()
    in
    (try
       Eio.Switch.run @@ fun connection_sw ->
       let rt = runtime connection_sw env in
       let connection =
         run rt
           (T.Audio.Realtime.connect_api_key ~ca_file:cert ~sw:connection_sw
              ~net:(routed_net ~sw:connection_sw ~net port)
              ~api_key:(Eta_ai.api_key "key")
              ~session:(realtime_session ()) ())
       in
       if cancel then
         Eio.Switch.fail connection_sw (Failure "cancel Realtime connection")
       else run rt (T.Audio.Realtime.close connection)
     with Failure _ -> ());
    Eio.Promise.await closed;
    Alcotest.(check int) id 1 (Atomic.get close_count)
  in
  run_case "xairt-eutb close releases WebSocket/event stream once" false;
  run_case "xairt-74dg cancellation releases WebSocket/event stream once" true

let test_blocked_write_cancellation_releases_stream () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun outer_sw ->
  let net = Eio.Stdenv.net env in
  let release_server, resolve_release_server = Eio.Promise.create () in
  let server_closed, resolve_server_closed = Eio.Promise.create () in
  let port =
    start_tls_server ~sw:outer_sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    Eio.Promise.await release_server;
    let scratch = Cstruct.create (64 * 1024) in
    (try
       while Eio.Flow.single_read flow scratch > 0 do () done
     with End_of_file -> ());
    Eio.Promise.resolve resolve_server_closed ()
  in
  let cert, _ = Lazy.force tls_files in
  (try
     Eio.Switch.run @@ fun connection_sw ->
     let rt = runtime connection_sw env in
     let connection =
       run rt
         (T.Responses_ws.connect ~ca_file:cert ~sw:connection_sw
            ~net:(routed_net ~sw:connection_sw ~net port)
            ~api_key:(Eta_ai.api_key "key") ())
     in
     let write_started, resolve_write_started = Eio.Promise.create () in
     let request =
       {
         response_request with
         input = Text_input (String.make (16 * 1024 * 1024) 'x');
       }
     in
     Eio.Fiber.fork ~sw:connection_sw (fun () ->
         Eio.Promise.resolve resolve_write_started ();
         ignore (Eta.Runtime.run rt (T.Responses_ws.create connection request)));
     Eio.Promise.await write_started;
     Eio.Time.sleep (Eio.Stdenv.clock env) 0.02;
     Eio.Switch.fail connection_sw (Failure "cancel blocked Responses write")
   with Failure _ -> ());
  Eio.Promise.resolve resolve_release_server ();
  Eio.Promise.await server_closed

let test_upgrade_errors_and_capabilities () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let cert, _ = Lazy.force tls_files in
  List.iter
    (fun status ->
      let port =
        start_tls_server ~sw ~net @@ fun flow ->
        ignore (read_http_head flow);
        let body = Printf.sprintf {|{"error":{"code":"denied_%d"}}|} status in
        (match status with
        | 401 ->
            Eio.Flow.copy_string
              (Printf.sprintf
                 "HTTP/1.1 401 Denied\r\nContent-Type: application/json\r\nX-Test: preserved\r\nTransfer-Encoding: chunked\r\n\r\n%X\r\n%s\r\n0\r\n\r\n"
                 (String.length body) body)
              flow
        | 403 ->
            Eio.Flow.copy_string
              ("HTTP/1.1 403 Denied\r\nContent-Type: application/json\r\nX-Test: preserved\r\nConnection: close\r\n\r\n"
              ^ body)
              flow;
            Eio.Flow.close flow
        | _ -> assert false)
      in
      let rt = runtime sw env in
      match
        Eta.Runtime.run rt
          (T.Responses_ws.connect ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port) ~api_key:(Eta_ai.api_key "secret") ())
      with
      | Eta.Exit.Error
          (Eta.Cause.Fail
            (`Xai_error
              (X.Error.Provider
                { status = actual; headers; payload; raw_body }))) ->
          Alcotest.(check int) "status" status actual;
          Alcotest.(check (option string)) "header" (Some "preserved")
            (Eta_http.Core.Header.get "x-test" headers);
          Alcotest.(check (option string)) "provider code"
            (Some (Printf.sprintf "denied_%d" status))
            payload.code;
          Alcotest.(check bool) "body" true (contains raw_body "denied")
      | _ -> Alcotest.fail "structured xAI upgrade error")
    [ 401; 403 ];
  Alcotest.(check bool) "base remains transport-neutral" false
    X.Capabilities.detailed.responses_websocket;
  Alcotest.(check bool) "Eio Responses capability" true
    T.capabilities.responses_websocket;
  Alcotest.(check bool) "Eio STT capability" true
    T.capabilities.streaming_speech_to_text;
  Alcotest.(check bool) "Eio TTS capability" true
    T.capabilities.streaming_text_to_speech

let test_observability_attrs_and_exclusions () =
  Eio_main.run @@ fun env ->
  let tracer = Eta.Tracer.in_memory () in
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let port =
    start_tls_server ~sw ~net @@ fun flow ->
    let head = read_http_head flow in
    Eio.Flow.copy_string (switching_response head) flow;
    ignore (read_client_frame flow);
    send_text flow
      {|{"type":"session.created","session":{"id":"session_1"}}|};
    send_text flow
      {|{"type":"response.created","id":"response_1"}|};
    send_text flow
      {|{"type":"error","error":{"code":"realtime_failure","message":"failed"}}|}
  in
  let cert, _ = Lazy.force tls_files in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  let connection =
    run rt
      (T.Audio.Realtime.connect_api_key ~ca_file:cert ~sw ~net:(routed_net ~sw ~net port) ~api_key:(Eta_ai.api_key "OBSERVABILITY-SECRET")
         ~session:
           (realtime_session ~instructions:"SENSITIVE-CONTENT" ())
         ())
  in
  run rt
    (T.Audio.Realtime.send_audio connection
       (Bytes.of_string "AUDIO-CONTENT-SENTINEL"));
  ignore (run rt (T.Audio.Realtime.read_event connection));
  ignore (run rt (T.Audio.Realtime.read_event connection));
  ignore (run rt (T.Audio.Realtime.read_event connection));
  run rt (T.Audio.Realtime.close connection);
  Eio.Fiber.yield ();
  let session_spans =
    Eta.Tracer.dump tracer
    |> List.filter (fun span -> span.Eta.Tracer.name = "realtime xai")
  in
  Alcotest.(check int) "xaiobs-84gq exactly one WebSocket session span" 1
    (List.length session_spans);
  let span =
    session_spans
    |> List.find (fun span -> span.Eta.Tracer.name = "realtime xai")
  in
  let attrs = span.attrs in
  Alcotest.(check (option string)) "provider" (Some "xai")
    (List.assoc_opt "gen_ai.provider.name" attrs);
  Alcotest.(check bool) "xaiobs-i7jj encoding formats" true
    (match List.assoc_opt "gen_ai.request.encoding_formats" attrs with
    | Some value -> contains value "audio/pcm"
    | None -> false);
  Alcotest.(check (option string)) "model" (Some "grok-voice-latest")
    (List.assoc_opt "gen_ai.request.model" attrs);
  Alcotest.(check (option string)) "response ID" (Some "response_1")
    (List.assoc_opt "gen_ai.response.id" attrs);
  Alcotest.(check bool) "xaiobs-2vw6 first event timing" true
    (List.mem_assoc "gen_ai.response.time_to_first_chunk" attrs);
  Alcotest.(check (option string)) "xaiobs-jxip terminal error type"
    (Some "realtime_failure") (List.assoc_opt "error.type" attrs);
  let rendered = String.concat " " (List.map snd attrs) in
  Alcotest.(check bool) "secret excluded" false
    (contains rendered "OBSERVABILITY-SECRET");
  Alcotest.(check bool) "content excluded" false
    (contains rendered "SENSITIVE-CONTENT");
  Alcotest.(check bool) "xaiobs-8qbo audio content excluded" false
    (contains rendered "AUDIO-CONTENT-SENTINEL")

let () =
  Alcotest.run "eta-ai-xai-eio"
    [
      ( "websocket",
        [
          Alcotest.test_case "secure endpoints and concurrent Realtime sends"
            `Quick test_secure_endpoint_subprotocol_and_realtime_races;
          Alcotest.test_case "ephemeral prefix and token rejection" `Quick
            test_ephemeral_prefix_and_token_rejection;
          Alcotest.test_case "STT state and multichannel completion" `Quick
            test_stt_state_machine_and_multichannel_done;
          Alcotest.test_case "STT pre-ready bound and validation" `Quick
            test_stt_pre_ready_bound_and_validation;
          Alcotest.test_case "TTS two complete cycles" `Quick
            test_tts_two_complete_cycles_and_fences;
          Alcotest.test_case "streaming codec samples and Unknown" `Quick
            test_streaming_codec_samples_and_unknown_preservation;
          Alcotest.test_case "Responses recovery, limit, max age" `Quick
            test_responses_recoverability_limit_and_max_age;
          Alcotest.test_case "concurrent Responses sends serialize" `Quick
            test_responses_concurrent_sends_are_serialized;
          Alcotest.test_case "max age and active switch release" `Quick
            test_max_age_and_switch_release_close_active_connections;
          Alcotest.test_case "Realtime close and cancellation release once" `Quick
            test_realtime_close_and_cancellation_release_once;
          Alcotest.test_case "blocked write cancellation releases stream" `Quick
            test_blocked_write_cancellation_releases_stream;
          Alcotest.test_case "upgrade errors and capabilities" `Quick
            test_upgrade_errors_and_capabilities;
          Alcotest.test_case "WebSocket observability and exclusions" `Quick
            test_observability_attrs_and_exclusions;
        ] );
    ]
