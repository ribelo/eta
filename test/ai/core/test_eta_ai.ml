open Eta_ai

let drain source =
  let pull = Audio.open_pull source in
  let buffer = Buffer.create 16 in
  let rec loop () =
    match pull () with
    | None -> Buffer.contents buffer
    | Some chunk ->
        Buffer.add_bytes buffer chunk;
        loop ()
  in
  loop ()

let test_oastt_59ol_bvq8_upload_sources () =
  let bytes = Audio.bytes (Bytes.of_string "bytes") in
  Alcotest.(check (option int64)) "bytes known length" (Some 5L)
    (Audio.known_length bytes);
  Alcotest.(check bool) "bytes replayable" true
    (Audio.replayability bytes = Audio.Replayable);
  Alcotest.(check string) "bytes first pull" "bytes" (drain bytes);
  Alcotest.(check string) "bytes replay" "bytes" (drain bytes);
  let opens = ref 0 in
  let source =
    Audio.stream ~length:6L ~replayability:Audio.Replayable (fun () ->
        incr opens;
        let chunks = ref [ Bytes.of_string "str"; Bytes.of_string "eam" ] in
        fun () ->
          match !chunks with
          | [] -> None
          | chunk :: rest ->
              chunks := rest;
              Some chunk)
  in
  Alcotest.(check (option int64)) "stream known length" (Some 6L)
    (Audio.known_length source);
  Alcotest.(check string) "stream pull chunks" "stream" (drain source);
  Alcotest.(check string) "stream replay opens a new puller" "stream"
    (drain source);
  Alcotest.(check int) "stream factory opened twice" 2 !opens;
  let one_shot =
    Audio.stream ~replayability:Audio.One_shot (fun () -> fun () -> None)
  in
  Alcotest.(check (option int64)) "unknown stream length" None
    (Audio.known_length one_shot);
  Alcotest.(check bool) "one-shot metadata" true
    (Audio.replayability one_shot = Audio.One_shot)

let test_oabridge_ctoh_neutral_subset_fields () =
  let upload : Audio.upload =
    {
      filename = "sample.wav";
      content_type = "audio/wav";
      source = Audio.bytes (Bytes.of_string "RIFF");
    }
  in
  let stt : Audio.Speech_to_text.request =
    { upload; language = Some "en" }
  in
  Alcotest.(check string) "STT filename" "sample.wav" stt.upload.filename;
  Alcotest.(check string) "STT content type" "audio/wav"
    stt.upload.content_type;
  Alcotest.(check (option string)) "STT language" (Some "en") stt.language;
  let transcript : Audio.Speech_to_text.result =
    {
      text = Some "hello";
      language = Some "en";
      duration_s = Some 1.25;
    }
  in
  Alcotest.(check (option string)) "STT text" (Some "hello") transcript.text;
  Alcotest.(check (option string)) "STT result language" (Some "en")
    transcript.language;
  Alcotest.(check (option (float 0.0))) "STT duration" (Some 1.25)
    transcript.duration_s;
  let tts : Audio.Text_to_speech.request =
    {
      text = "hello";
      voice = "voice";
      encoding = Some Audio.Text_to_speech.Wav;
      speed = Some 1.1;
    }
  in
  Alcotest.(check string) "TTS text" "hello" tts.text;
  Alcotest.(check string) "TTS voice" "voice" tts.voice;
  Alcotest.(check bool) "TTS shared encoding" true
    (tts.encoding = Some Audio.Text_to_speech.Wav);
  Alcotest.(check (option (float 0.0))) "TTS speed" (Some 1.1) tts.speed;
  let audio : Audio.Text_to_speech.result =
    { content_type = Some "audio/wav"; audio = Bytes.of_string "WAV" }
  in
  Alcotest.(check (option string)) "TTS content type" (Some "audio/wav")
    audio.content_type;
  Alcotest.(check string) "TTS audio" "WAV" (Bytes.to_string audio.audio)

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
            replay_items = [];
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
            retry_after_s = None;
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
              retry_after_s = None;
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
      ( "audio",
        [
          Alcotest.test_case "oastt-59ol/bvq8 upload source behavior" `Quick
            test_oastt_59ol_bvq8_upload_sources;
          Alcotest.test_case "oabridge-ctoh neutral subset field coverage" `Quick
            test_oabridge_ctoh_neutral_subset_fields;
        ] );
      ( "provider-transport",
        [
          Alcotest.test_case "error body max bytes before decode" `Quick
            test_transport_caps_error_body_before_provider_decode;
        ] );
    ]
