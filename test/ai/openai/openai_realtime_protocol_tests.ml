module A = Eta_ai
module R = Eta_ai_openai.Audio.Realtime

let contains ~needle value =
  let n = String.length needle in
  let rec loop i =
    i + n <= String.length value
    && (String.sub value i n = needle || loop (i + 1))
  in
  n = 0 || loop 0

let require label needle value =
  Alcotest.(check bool) label true (contains ~needle value)

let audio () =
  match A.audio_pcm16_base64 "AAECAw==" with
  | A.Audio audio -> audio
  | _ -> Alcotest.fail "expected audio"

let test_oartc_sibling_codec_contracts () =
  let module C : A.Realtime.Codec
    with type session = R.Conversation.session
     and type client_event = R.Conversation.client_event
     and type server_event = R.Conversation.server_event
     and type error = R.Conversation.codec_error = R.Conversation.Codec in
  let module T : A.Realtime.Codec
    with type session = R.Transcription.session
     and type client_event = R.Transcription.client_event
     and type server_event = R.Transcription.server_event
     and type error = R.Transcription.codec_error = R.Transcription.Codec in
  let module L : A.Realtime.Codec
    with type session = R.Translation.session
     and type client_event = R.Translation.client_event
     and type server_event = R.Translation.server_event
     and type error = R.Translation.codec_error = R.Translation.Codec in
  ignore (module C : A.Realtime.Codec);
  ignore (module T : A.Realtime.Codec);
  ignore (module L : A.Realtime.Codec);
  match R.Conversation.decode_server_event
      {|{"type":"conversation.future","nested":{"keep":true}}|} with
  | Ok (R.Conversation.Unknown
      { type_ = "conversation.future"; raw }) ->
      Alcotest.(check bool) "conversation unknown complete" true
        (A.Json.object_member "nested" raw <> None)
  | _ -> Alcotest.fail "expected conversation Unknown"

let test_oartt_session_full_fidelity () =
  let turn_detection = `Assoc [ ("type", `String "server_vad"); ("threshold", `Float 0.4) ] in
  let session =
    R.Transcription.session ~input_audio_format:R.Transcription.Pcm16_24khz
      ~model:"gpt-live-transcribe" ~prompt:"support AC-42"
      ~keywords:[ "AC-42"; "billing" ] ~languages:[ "en"; "fr" ]
      ~delay:R.Transcription.Low ~turn_detection ~include_:[ "item.input_audio_transcription.logprobs" ] ()
    |> Result.get_ok
  in
  let raw = R.Transcription.session_to_string session in
  List.iter (fun needle -> require needle needle raw)
    [ "\"type\":\"transcription\""; "\"type\":\"audio/pcm\"";
      "\"model\":\"gpt-live-transcribe\""; "\"prompt\":\"support AC-42\"";
      "\"keywords\":[\"AC-42\",\"billing\"]"; "\"languages\":[\"en\",\"fr\"]";
      "\"delay\":\"low\""; "\"turn_detection\":{"; "\"include\":[" ];
  let committed =
    R.Transcription.session ~input_audio_format:R.Transcription.Pcm16_24khz ~model:"gpt-transcribe" ()
    |> Result.get_ok
    |> R.Transcription.session_to_string
  in
  require "committed model" "\"model\":\"gpt-transcribe\"" committed;
  require "disabled turn detection is explicit" "\"turn_detection\":null" committed;
  let legacy_language =
    R.Transcription.session
      ~input_audio_format:R.Transcription.Pcm16_24khz ~model:"whisper-1"
      ~language:"en" ()
    |> Result.get_ok |> R.Transcription.session_to_string
  in
  require "legacy singular language" "\"language\":\"en\"" legacy_language

let test_oartt_event_identity_languages_and_raw () =
  let completed item transcript languages marker =
    Printf.sprintf
      {|{"type":"conversation.item.input_audio_transcription.completed","event_id":"ev-%s","item_id":"%s","content_index":0,"transcript":"%s","languages":%s,"marker":"%s"}|}
      item item transcript languages marker
  in
  let decode raw =
    match R.Transcription.decode_server_event raw with
    | Ok (R.Transcription.Transcription_completed
        { item_id; content_index; languages; raw; _ }) ->
        (item_id, content_index, languages, raw)
    | _ -> Alcotest.fail "expected completed transcription"
  in
  (* oartt-nkg1: completions intentionally arrive in reverse item order. *)
  let second_id, second_index, second_languages, second_raw =
    decode (completed "item-2" "deux" "[{\"code\":\"fr\"}]" "second")
  in
  let first_id, _, first_languages, _ =
    decode (completed "item-1" "one" "[]" "first")
  in
  Alcotest.(check string) "reverse completion keeps second id" "item-2" second_id;
  Alcotest.(check string) "reverse completion keeps first id" "item-1" first_id;
  Alcotest.(check int) "content index" 0 second_index;
  Alcotest.(check (option int)) "empty languages is successful" (Some 0)
    (Option.map List.length first_languages);
  Alcotest.(check (option string)) "detected language" (Some "fr")
    (match second_languages with Some [ language ] -> Some language.code | _ -> None);
  Alcotest.(check (option string)) "complete raw unknown field" (Some "second")
    (A.Json.string_member "marker" second_raw)

let test_oartt_delta_unknown_and_decode () =
  (match R.Transcription.decode_server_event
     {|{"type":"conversation.item.input_audio_transcription.delta","event_id":"ev-3","item_id":"item-3","content_index":4,"delta":"Hi","extra":17}|} with
   | Ok (R.Transcription.Transcription_delta event) ->
       Alcotest.(check string) "event id" "ev-3" event.event_id;
       Alcotest.(check string) "item" "item-3" event.item_id;
       Alcotest.(check int) "index" 4 event.content_index;
       Alcotest.(check string) "delta" "Hi" event.delta;
       Alcotest.(check (option int)) "raw extra" (Some 17) (A.Json.int_member "extra" event.raw)
   | _ -> Alcotest.fail "expected delta");
  (match R.Transcription.decode_server_event {|{"type":"future.transcript","payload":{"x":1}}|} with
   | Ok (R.Transcription.Unknown { type_ = "future.transcript"; raw }) ->
       Alcotest.(check bool) "complete unknown raw" true (A.Json.object_member "payload" raw <> None)
   | _ -> Alcotest.fail "expected unknown");
  match R.Transcription.Codec.decode_server_event (A.Realtime.Text "{bad") with
  | Error (R.Transcription.Decode { raw_body = Some "{bad"; _ }) -> ()
  | _ -> Alcotest.fail "malformed frame must be a codec Decode"

let test_oartc_documented_audio_event_matrix () =
  let client_cases =
    [
      (R.Conversation.Input_audio_buffer_clear { event_id = Some "clear" },
       "input_audio_buffer.clear");
      (R.Conversation.Conversation_item_truncate
         { item_id = "i"; content_index = 0; audio_end_ms = 10;
           event_id = Some "truncate" },
       "conversation.item.truncate");
      (R.Conversation.Response_cancel
         { response_id = Some "r"; event_id = Some "cancel" },
       "response.cancel");
      (R.Conversation.Output_audio_buffer_clear { event_id = Some "output" },
       "output_audio_buffer.clear");
    ]
  in
  List.iter
    (fun (event, expected) ->
      let json = R.Conversation.client_event_json event in
      Alcotest.(check (option string)) expected (Some expected)
        (A.Json.string_member "type" json))
    client_cases;
  let event_name =
    let open R.Conversation in
    function
    | R.Conversation.Session_updated _ -> "session.updated"
    | Conversation_created _ -> "conversation.created"
    | Conversation_item_created _ -> "conversation.item.created"
    | Conversation_item_deleted _ -> "conversation.item.deleted"
    | Conversation_item_retrieved _ -> "conversation.item.retrieved"
    | Conversation_item_truncated _ -> "conversation.item.truncated"
    | Conversation_item_added _ -> "conversation.item.added"
    | Conversation_item_done _ -> "conversation.item.done"
    | Response_audio_done _ -> "response.output_audio.done"
    | Response_audio_transcript_delta _ ->
        "response.output_audio_transcript.delta"
    | Response_audio_transcript_done _ ->
        "response.output_audio_transcript.done"
    | Response_content_part_added _ -> "response.content_part.added"
    | Response_content_part_done _ -> "response.content_part.done"
    | Response_function_call_arguments_delta _ ->
        "response.function_call_arguments.delta"
    | Response_function_call_arguments_done _ ->
        "response.function_call_arguments.done"
    | Response_output_item_added _ -> "response.output_item.added"
    | Response_output_item_done _ -> "response.output_item.done"
    | Response_output_text_done _ -> "response.output_text.done"
    | Input_audio_buffer_cleared _ -> "input_audio_buffer.cleared"
    | Input_audio_speech_started _ -> "input_audio_buffer.speech_started"
    | Input_audio_speech_stopped _ -> "input_audio_buffer.speech_stopped"
    | Input_audio_timeout_triggered _ -> "input_audio_buffer.timeout_triggered"
    | Input_audio_dtmf_received _ -> "input_audio_buffer.dtmf_event_received"
    | Input_audio_transcription_delta _ ->
        "conversation.item.input_audio_transcription.delta"
    | Input_audio_transcription_completed _ ->
        "conversation.item.input_audio_transcription.completed"
    | Input_audio_transcription_failed _ ->
        "conversation.item.input_audio_transcription.failed"
    | Input_audio_transcription_segment _ ->
        "conversation.item.input_audio_transcription.segment"
    | Output_audio_buffer_started _ -> "output_audio_buffer.started"
    | Output_audio_buffer_stopped _ -> "output_audio_buffer.stopped"
    | Output_audio_buffer_cleared _ -> "output_audio_buffer.cleared"
    | Rate_limits_updated _ -> "rate_limits.updated"
    | _ -> "wrong-constructor"
  in
  let simple =
    [ "session.updated"; "conversation.created"; "conversation.item.created";
      "conversation.item.deleted"; "conversation.item.retrieved";
      "conversation.item.truncated"; "conversation.item.added";
      "conversation.item.done"; "response.output_audio.done";
      "response.output_audio_transcript.done"; "response.content_part.added";
      "response.content_part.done"; "response.function_call_arguments.delta";
      "response.function_call_arguments.done"; "response.output_item.added";
      "response.output_item.done"; "response.output_text.done";
      "input_audio_buffer.cleared"; "input_audio_buffer.speech_started";
      "input_audio_buffer.speech_stopped"; "input_audio_buffer.timeout_triggered";
      "input_audio_buffer.dtmf_event_received";
      "conversation.item.input_audio_transcription.segment";
      "output_audio_buffer.started"; "output_audio_buffer.stopped";
      "output_audio_buffer.cleared"; "rate_limits.updated" ]
  in
  let cases =
    List.map (fun type_ -> (type_, Printf.sprintf {|{"type":"%s"}|} type_))
      simple
    @ [
      ("response.output_audio_transcript.delta",
       {|{"type":"response.output_audio_transcript.delta","delta":"text"}|});
      ("conversation.item.input_audio_transcription.delta",
       {|{"type":"conversation.item.input_audio_transcription.delta","item_id":"i","content_index":0,"delta":"d"}|});
      ("conversation.item.input_audio_transcription.completed",
       {|{"type":"conversation.item.input_audio_transcription.completed","item_id":"i","content_index":0,"transcript":"done"}|});
      ("conversation.item.input_audio_transcription.failed",
       {|{"type":"conversation.item.input_audio_transcription.failed","item_id":"i","content_index":0,"error":{"type":"transcription_error"}}|});
    ]
  in
  List.iter
    (fun (expected, raw) ->
      match R.Conversation.decode_server_event raw with
      | Ok event ->
          Alcotest.(check string) expected expected (event_name event)
      | Error _ -> Alcotest.fail ("failed to decode " ^ expected))
    cases

let test_oartt_noise_clear_failure_and_formats () =
  let formats =
    [ (R.Transcription.Pcm16_24khz, "\"type\":\"audio/pcm\"");
      (R.Transcription.G711_ulaw, "\"type\":\"audio/pcmu\"");
      (R.Transcription.G711_alaw, "\"type\":\"audio/pcma\"") ]
  in
  List.iter
    (fun (input_audio_format, needle) ->
      R.Transcription.session ~input_audio_format ~model:"gpt-live-transcribe" ()
      |> Result.get_ok
      |> R.Transcription.session_to_string |> require needle needle)
    formats;
  let session =
    R.Transcription.session ~input_audio_format:R.Transcription.Pcm16_24khz
      ~noise_reduction:R.Transcription.Far_field
      ~model:"gpt-live-transcribe" ()
    |> Result.get_ok
  in
  require "noise reduction" "\"noise_reduction\":{\"type\":\"far_field\"}"
    (R.Transcription.session_to_string session);
  let clear =
    R.Transcription.client_event_to_string
      (R.Transcription.Input_audio_buffer_clear { event_id = Some "clear" })
  in
  require "clear event" "\"type\":\"input_audio_buffer.clear\"" clear;
  match R.Transcription.decode_server_event
      {|{"type":"conversation.item.input_audio_transcription.failed","event_id":"e","item_id":"i","content_index":2,"error":{"type":"transcription_error","code":"bad"}}|} with
  | Ok (R.Transcription.Transcription_failed
      { item_id = "i"; content_index = 2; error; _ }) ->
      Alcotest.(check (option string)) "error code" (Some "bad")
        (A.Json.string_member "code" error)
  | _ -> Alcotest.fail "expected typed transcription failure"

let test_m5_malformed_event_shapes_and_languages () =
  let malformed =
    [ "{}"; "[]"; "\"scalar\""; "42"; "null"; {|{"type":42}|} ]
  in
  List.iter
    (fun raw ->
      let failed = function Error _ -> true | Ok _ -> false in
      Alcotest.(check bool) ("conversation " ^ raw) true
        (failed (R.Conversation.decode_server_event raw));
      Alcotest.(check bool) ("transcription " ^ raw) true
        (failed (R.Transcription.decode_server_event raw));
      Alcotest.(check bool) ("translation " ^ raw) true
        (failed (R.Translation.decode_server_event raw)))
    malformed;
  let malformed_language =
    {|{"type":"conversation.item.input_audio_transcription.completed","item_id":"i","content_index":0,"transcript":"x","languages":[{"wrong":"fr"}]}|}
  in
  (match R.Transcription.decode_server_event malformed_language with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "malformed language entry was filtered");
  let bad_format =
    {|{"type":"session.output_audio.delta","event_id":"e","delta":"x","format":"opus"}|}
  in
  match R.Translation.decode_server_event bad_format with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "undocumented translation format was accepted"

let test_oartr_session_and_client_vocabulary () =
  let session =
    R.Translation.session ~model:"gpt-realtime-translate" ~output_language:"es"
      ~input_transcription:(R.Translation.Model "gpt-realtime-whisper")
      ~noise_reduction:R.Translation.Near_field ()
  in
  let raw = R.Translation.session_to_string session in
  require "target language" "\"language\":\"es\"" raw;
  require "source transcript model" "\"model\":\"gpt-realtime-whisper\"" raw;
  require "noise reduction" "\"type\":\"near_field\"" raw;
  let append = R.Translation.client_event_to_string
      (R.Translation.Input_audio_buffer_append { audio = audio (); event_id = Some "a1" }) in
  require "translation append prefix" "\"type\":\"session.input_audio_buffer.append\"" append;
  let close = R.Translation.client_event_to_string (R.Translation.Session_close { event_id = Some "c1" }) in
  require "translation close" "\"type\":\"session.close\"" close;
  Alcotest.(check bool) "translation vocabulary has no response.create" false
    (contains ~needle:"response.create" (append ^ close ^ raw))

let test_oartr_typed_output_and_unknown () =
  (match R.Translation.decode_server_event
     {|{"type":"session.output_audio.delta","event_id":"e1","delta":"AAE=","channels":1,"elapsed_ms":1200,"format":"pcm16","sample_rate":24000,"marker":"raw"}|} with
   | Ok (R.Translation.Output_audio_delta event) ->
       Alcotest.(check string) "audio" "AAE=" event.delta;
       Alcotest.(check (option int)) "channels" (Some 1) event.channels;
       Alcotest.(check (option int)) "elapsed" (Some 1200) event.elapsed_ms;
       Alcotest.(check (option string)) "format" (Some "pcm16")
         (Option.map (function `Pcm16 -> "pcm16") event.format);
       Alcotest.(check (option int)) "rate" (Some 24000) event.sample_rate;
       Alcotest.(check (option string)) "complete raw" (Some "raw") (A.Json.string_member "marker" event.raw)
   | _ -> Alcotest.fail "expected output audio");
  (match R.Translation.decode_server_event
      {|{"type":"session.output_transcript.delta","event_id":"out-1","delta":"translated","elapsed_ms":200}|} with
   | Ok (R.Translation.Output_transcript_delta { delta = "translated"; _ }) -> ()
   | _ -> Alcotest.fail "output transcript decoded to wrong constructor");
  (match R.Translation.decode_server_event
      {|{"type":"session.input_transcript.delta","event_id":"in-1","delta":"source","elapsed_ms":200}|} with
   | Ok (R.Translation.Input_transcript_delta { delta = "source"; _ }) -> ()
   | _ -> Alcotest.fail "input transcript decoded to wrong constructor");
  match R.Translation.decode_server_event {|{"type":"session.future","nested":{"keep":true}}|} with
  | Ok (R.Translation.Unknown { type_ = "session.future"; raw }) ->
      Alcotest.(check bool) "unknown complete" true (A.Json.object_member "nested" raw <> None)
  | _ -> Alcotest.fail "expected translation Unknown"


let expect_invalid label = function
  | Error (Eta_ai_openai.Error.Invalid_request message) ->
      Alcotest.(check bool) (label ^ " diagnostic") true
        (String.length message > 0)
  | Error _ -> Alcotest.fail (label ^ ": wrong error")
  | Ok _ -> Alcotest.fail (label ^ ": unexpectedly valid")

let test_oartc_conversation_session_full_fidelity () =
  let module C = R.Conversation in
  let session =
    C.session ~model:"gpt-realtime-2" ~instructions:"stay brief"
      ~input_audio_format:C.Pcm16_24khz
      ~input_noise_reduction:C.Near_field
      ~input_transcription:
        (C.Transcription
           {
             model = Some "gpt-4o-transcribe";
             language = Some "en";
             languages = [];
             prompt = Some "support call";
             keywords = [];
             delay = None;
           })
      ~turn_detection:C.Turn_detection_off
      ~output_audio_format:C.G711_alaw ~output_speed:0.75
      ~voice:(C.Custom "voice_1234") ~include_logprobs:true
      ~max_output_tokens:C.Infinite ~parallel_tool_calls:false
      ~prompt:(`Assoc [ ("id", `String "pmpt_1") ])
      ~reasoning:(`Assoc [ ("effort", `String "high") ])
      ~tracing:C.Tracing_auto
      ~truncation:
        (C.Retention_ratio { ratio = 0.8; token_limits = None })
      ~extra:[ ("x-custom", `Bool true) ] ()
    |> Result.get_ok
  in
  let raw = C.session_to_string session in
  List.iter
    (fun (label, needle) -> require label needle raw)
    [
      ("model", "\"model\":\"gpt-realtime-2\"");
      ("noise reduction", "\"noise_reduction\":{\"type\":\"near_field\"}");
      ("input transcription model", "\"transcription\":{\"model\":\"gpt-4o-transcribe\"");
      ("language", "\"language\":\"en\"");

      ("turn detection off", "\"turn_detection\":null");
      ("output format", "\"audio/pcma\"");
      ("speed", "\"speed\":0.75");
      ("custom voice", "\"voice\":{\"id\":\"voice_1234\"}");
      ("include logprobs", "\"include\":[\"item.input_audio_transcription.logprobs\"]");
      ("infinite tokens", "\"max_output_tokens\":\"inf\"");
      ("parallel tool calls", "\"parallel_tool_calls\":false");
      ("prompt", "\"prompt\":{\"id\":\"pmpt_1\"}");
      ("reasoning", "\"reasoning\":{\"effort\":\"high\"}");
      ("tracing", "\"tracing\":\"auto\"");
      ("truncation", "\"truncation\":{\"type\":\"retention_ratio\",\"retention_ratio\":0.8}");
      ("extra passthrough", "\"x-custom\":true");
    ];
  let plural_languages =
    C.session ~model:"gpt-realtime-2"
      ~input_transcription:
        (C.Transcription
           { model = Some "gpt-transcribe"; language = None;
             languages = [ "en"; "fr" ]; prompt = None;
             keywords = [ "billing" ];
             delay = None })
      ()
    |> Result.get_ok |> C.session_to_string
  in
  require "plural languages" "\"languages\":[\"en\",\"fr\"]"
    plural_languages;
  require "plural-model keywords" "\"keywords\":[\"billing\"]"
    plural_languages;
  let whisper =
    C.session ~model:"gpt-realtime-2"
      ~input_transcription:
        (C.Transcription
           { model = Some "gpt-realtime-whisper"; language = None;
             languages = []; prompt = None; keywords = []; delay = Some C.Low })
      ~turn_detection:C.Turn_detection_off ()
    |> Result.get_ok
  in
  require "whisper delay" "\"delay\":\"low\"" (C.session_to_string whisper)

let test_oaerr_conversation_session_validation () =
  let module C = R.Conversation in
  expect_invalid "empty modalities" (C.session ~output_modalities:[] ());
  expect_invalid "repeated modalities"
    (C.session ~output_modalities:[ C.Audio; C.Audio ] ());
  expect_invalid "text and audio together"
    (C.session ~output_modalities:[ C.Text; C.Audio ] ());
  expect_invalid "speed below range"
    (C.session ~output_speed:0.1 ());
  expect_invalid "speed above range"
    (C.session ~output_speed:2.0 ());
  expect_invalid "non-finite speed"
    (C.session ~output_speed:nan ());
  expect_invalid "zero max output tokens"
    (C.session ~max_output_tokens:(C.Tokens 0) ());
  expect_invalid "negative max output tokens"
    (C.session ~max_output_tokens:(C.Tokens (-5)) ());
  expect_invalid "tokens above documented range"
    (C.session ~max_output_tokens:(C.Tokens 4097) ());
  expect_invalid "retention ratio above one"
    (C.session
       ~truncation:(C.Retention_ratio { ratio = 1.5; token_limits = None })
       ());
  expect_invalid "non-finite retention ratio"
    (C.session
       ~truncation:(C.Retention_ratio { ratio = nan; token_limits = None })
       ());
  expect_invalid "turn detection threshold above one"
    (C.session
       ~turn_detection:
         (C.Turn_detection
            (`Assoc [ ("type", `String "server_vad"); ("threshold", `Float 1.5) ]))
       ());
  expect_invalid "turn detection negative timeout"
    (C.session
       ~turn_detection:
         (C.Turn_detection
            (`Assoc [ ("type", `String "server_vad"); ("idle_timeout_ms", `Int (-1)) ]))
       ());
  List.iter
    (fun name ->
      expect_invalid ("extra collision with " ^ name)
        (C.session ~extra:[ (name, `Null) ] ()))
    [ "type"; "model"; "instructions"; "output_modalities"; "audio";
      "include"; "max_output_tokens"; "parallel_tool_calls"; "prompt";
      "reasoning"; "tools"; "tool_choice"; "tracing"; "truncation" ];
  List.iter
    (fun keyword ->
      expect_invalid ("keyword containing " ^ String.escaped keyword)
        (C.session
           ~input_transcription:
             (C.Transcription
                { model = None; language = None; languages = [];
                  prompt = None; keywords = [ keyword ]; delay = None })
           ()))
    [ "a<b"; "a>b"; "a\rb"; "a\nb" ];
  expect_invalid "singular and plural transcription languages"
    (C.session
       ~input_transcription:
         (C.Transcription
            { model = Some "gpt-transcribe"; language = Some "en";
              languages = [ "en"; "fr" ]; prompt = None; keywords = [];
              delay = None })
       ());
  let transcription ?(model = None) ?(prompt = None) ?(delay = None) () =
    C.Transcription
      { model; language = None; languages = []; prompt; keywords = [];
        delay }
  in
  expect_invalid "delay with gpt-transcribe"
    (C.session
       ~input_transcription:
         (transcription ~model:(Some "gpt-transcribe") ~delay:(Some C.Low) ())
       ());
  expect_invalid "prompt with gpt-realtime-whisper"
    (C.session
       ~input_transcription:
         (transcription ~model:(Some "gpt-realtime-whisper")
            ~prompt:(Some "hint") ())
       ~turn_detection:C.Turn_detection_off ());
  expect_invalid "turn detection with gpt-realtime-whisper"
    (C.session
       ~input_transcription:
         (transcription ~model:(Some "gpt-realtime-whisper") ())
       ~turn_detection:
         (C.Turn_detection (`Assoc [ ("type", `String "server_vad") ]))
       ());
  expect_invalid "omitted turn detection with gpt-realtime-whisper"
    (C.session
       ~input_transcription:
         (transcription ~model:(Some "gpt-realtime-whisper") ())
       ());
  (match
     C.session
       ~input_transcription:(transcription ~delay:(Some C.Low) ()) ()
   with
   | Ok _ -> ()
   | Error _ ->
       Alcotest.fail
         "delay with a provider-selected transcription model was rejected");
  let raw =
    C.session_to_string
      (C.session ~model:"gpt-realtime-2"
         ~tool_choice:(C.Function_tool "weather") ()
      |> Result.get_ok)
  in
  require "function tool choice"
    "\"tool_choice\":{\"type\":\"function\",\"name\":\"weather\"}" raw;
  let raw =
    C.session_to_string
      (C.session ~model:"gpt-realtime-2"
         ~input_transcription:
           (C.Transcription
              { model = None; language = None; languages = []; prompt = None;
                keywords = []; delay = None })
         ()
      |> Result.get_ok)
  in
  require "optional transcription model omitted" "\"transcription\":{}" raw;
  let raw = C.session_to_string (C.session () |> Result.get_ok) in
  require "default modalities are audio only" "\"output_modalities\":[\"audio\"]" raw


let test_oaerr_transcription_session_validation () =
  let module T = R.Transcription in
  let expect_invalid label = function
    | Error (Eta_ai_openai.Error.Invalid_request _) -> ()
    | Error _ -> Alcotest.fail (label ^ " returned the wrong error")
    | Ok _ -> Alcotest.fail (label ^ " was accepted")
  in
  expect_invalid "malformed keyword"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"gpt-live-transcribe" ~keywords:[ "bad\nkeyword" ] ());
  expect_invalid "whisper prompt"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"gpt-realtime-whisper" ~prompt:"hint" ());
  expect_invalid "whisper turn detection"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"gpt-realtime-whisper"
       ~turn_detection:(`Assoc [ ("type", `String "server_vad") ]) ());
  let whisper =
    T.session ~input_audio_format:T.Pcm16_24khz
      ~model:"gpt-realtime-whisper" ~delay:T.Low ()
    |> Result.get_ok |> T.session_to_string
  in
  require "whisper explicit null turn detection" "\"turn_detection\":null"
    whisper;
  let explicit_null =
    T.session ~input_audio_format:T.Pcm16_24khz
      ~model:"gpt-realtime-whisper" ~turn_detection:`Null ()
    |> Result.get_ok |> T.session_to_string
  in
  require "whisper supplied null turn detection" "\"turn_detection\":null"
    explicit_null;
  let live =
    T.session ~input_audio_format:T.Pcm16_24khz
      ~model:"gpt-live-transcribe" ~delay:T.Low ()
    |> Result.get_ok |> T.session_to_string
  in
  require "live transcription delay remains valid" "\"delay\":\"low\"" live

let test_oaerr_transcription_model_matrix () =
  let module C = R.Conversation in
  let module T = R.Transcription in
  let expect_ok label = function
    | Ok _ -> ()
    | Error error ->
        Alcotest.failf "%s unexpectedly failed: %a" label
          Eta_ai_openai.Error.pp error
  in
  let conversation ?language ?(languages = []) ?prompt ?(keywords = [])
      ?delay model =
    let input_transcription =
      C.Transcription
        { model = Some model; language; languages; prompt; keywords; delay }
    in
    if model = "gpt-realtime-whisper" then
      C.session ~input_transcription ~turn_detection:C.Turn_detection_off ()
    else C.session ~input_transcription ()
  in
  let plural_models = [ "gpt-transcribe"; "gpt-live-transcribe" ] in
  let legacy_models =
    [ "whisper-1"; "gpt-4o-mini-transcribe";
      "gpt-4o-mini-transcribe-2025-12-15"; "gpt-4o-transcribe";
      "gpt-4o-transcribe-diarize"; "gpt-realtime-whisper" ]
  in
  List.iter
    (fun model ->
      expect_invalid (model ^ " singular language")
        (conversation ~language:"en" model);
      expect_invalid (model ^ " dedicated singular language")
        (T.session ~input_audio_format:T.Pcm16_24khz ~model ~language:"en" ());
      expect_ok (model ^ " plural languages and keywords")
        (conversation ~languages:[ "en"; "fr" ] ~prompt:"hint"
           ~keywords:[ "Eta" ] model);
      expect_invalid (model ^ " conversation delay")
        (conversation ~delay:C.Low model);
      expect_ok (model ^ " dedicated plural languages and keywords")
        (T.session ~input_audio_format:T.Pcm16_24khz ~model
           ~languages:[ "en"; "fr" ] ~prompt:"hint" ~keywords:[ "Eta" ] ());
      if model = "gpt-live-transcribe" then
        expect_ok "live dedicated delay"
          (T.session ~input_audio_format:T.Pcm16_24khz ~model ~delay:T.Low ())
      else
        expect_invalid "gpt-transcribe dedicated delay"
          (T.session ~input_audio_format:T.Pcm16_24khz ~model ~delay:T.Low ()))
    plural_models;
  List.iter
    (fun model ->
      expect_invalid (model ^ " plural languages")
        (conversation ~languages:[ "en" ] model);
      expect_invalid (model ^ " keywords")
        (conversation ~keywords:[ "Eta" ] model);
      expect_ok (model ^ " singular language")
        (conversation ~language:"en" model);
      expect_ok (model ^ " dedicated singular language")
        (T.session ~input_audio_format:T.Pcm16_24khz ~model ~language:"en" ());
      expect_invalid (model ^ " dedicated plural languages")
        (T.session ~input_audio_format:T.Pcm16_24khz ~model
           ~languages:[ "en" ] ());
      expect_invalid (model ^ " dedicated keywords")
        (T.session ~input_audio_format:T.Pcm16_24khz ~model
           ~keywords:[ "Eta" ] ());
      if model <> "gpt-realtime-whisper" then
        (expect_invalid (model ^ " conversation delay")
           (conversation ~delay:C.Low model);
         expect_invalid (model ^ " dedicated delay")
           (T.session ~input_audio_format:T.Pcm16_24khz ~model ~delay:T.Low ()))
      else
        expect_ok "whisper dedicated delay"
          (T.session ~input_audio_format:T.Pcm16_24khz ~model ~delay:T.Low ()))
    legacy_models;
  expect_ok "whisper conversation delay"
    (conversation ~delay:C.Low "gpt-realtime-whisper");
  expect_invalid "diarization Conversation prompt"
    (conversation ~prompt:"hint" "gpt-4o-transcribe-diarize");
  expect_invalid "diarization Transcription prompt"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"gpt-4o-transcribe-diarize" ~prompt:"hint" ());
  expect_ok "ordinary gpt-4o prompt"
    (conversation ~prompt:"hint" "gpt-4o-transcribe");
  expect_ok "unknown future Conversation model fields"
    (conversation ~languages:[ "en" ] ~prompt:"hint" ~keywords:[ "Eta" ]
       ~delay:C.Low "future-transcribe-v1");
  expect_ok "unknown future Transcription model fields"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"future-transcribe-v1" ~languages:[ "en" ] ~prompt:"hint"
       ~keywords:[ "Eta" ] ~delay:T.Low ());
  expect_ok "unknown future Transcription singular language"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"future-transcribe-v1" ~language:"en" ());
  expect_invalid "unknown future Transcription mixed languages"
    (T.session ~input_audio_format:T.Pcm16_24khz
       ~model:"future-transcribe-v1" ~language:"en" ~languages:[ "fr" ] ())

let test_oaerr_turn_detection_numeric_matrix () =
  let fields =
    [ "threshold"; "idle_timeout_ms"; "prefix_padding_ms";
      "silence_duration_ms" ]
  in
  let representations = [ "int"; "float"; "intlit" ] in
  let cases =
    List.concat_map
      (fun field ->
        List.concat_map
          (fun representation ->
            let values =
              match representation with
              | "int" ->
                  [ (`Int (-1), -1.0); (`Int 0, 0.0); (`Int 1, 1.0);
                    (`Int 2, 2.0) ]
              | "float" ->
                  [ (`Float (-0.5), -0.5); (`Float 0.0, 0.0);
                    (`Float 1.0, 1.0); (`Float 1.5, 1.5) ]
              | "intlit" ->
                  [ (`Intlit "-1", -1.0); (`Intlit "0", 0.0);
                    (`Intlit "1", 1.0); (`Intlit "2", 2.0) ]
              | _ -> assert false
            in
            List.map
              (fun (json, numeric) ->
                let expected =
                  match field with
                  | "threshold" -> numeric >= 0.0 && numeric <= 1.0
                  | _ -> numeric >= 0.0
                in
                (field, representation, json, expected))
              values)
          representations)
      fields
  in
  let nonfinite =
    List.concat_map
      (fun field ->
        [ (field, "float-nan", `Float nan, false);
          (field, "float-infinity", `Float infinity, false) ])
      fields
  in
  let nonnumeric =
    let malformed_intlits =
      [ "not-an-integer"; "+1"; "0x1"; "1_0"; "1."; "01" ]
    in
    List.concat_map
      (fun field ->
        [ (field, "string", `String "invalid", false);
          (field, "null", `Null, String.equal field "idle_timeout_ms") ]
        @ List.map
            (fun value ->
              (field, "malformed-intlit", `Intlit value, false))
            malformed_intlits)
      fields
  in
  let huge_positive = String.make 400 '9' in
  let large_intlits =
    List.map
      (fun field ->
        ( field,
          "large-intlit",
          `Intlit huge_positive,
          not (String.equal field "threshold") ))
      fields
  in
  let cases = cases @ nonfinite @ nonnumeric @ large_intlits in
  Alcotest.(check int) "guarded numeric classes" 92 (List.length cases);
  let json_label = function
    | `Float value when Float.is_nan value -> "Float(nan)"
    | `Float value when not (Float.is_finite value) ->
        Printf.sprintf "Float(%F)" value
    | json -> Eta_ai.Json.to_string json
  in
  List.iter
    (fun (field, representation, json, expected) ->
      let turn_detection =
        `Assoc [ ("type", `String "server_vad"); (field, json) ]
      in
      let check provider actual =
        if actual <> expected then
          Alcotest.failf
            "%s field=%s representation=%s json=%s expected-valid=%b actual-valid=%b"
            provider field representation (json_label json) expected actual
      in
      check "Conversation"
        (R.Conversation.session ~model:"gpt-realtime-2"
           ~turn_detection:(R.Conversation.Turn_detection turn_detection) ()
        |> Result.is_ok);
      check "Transcription"
        (R.Transcription.session
           ~input_audio_format:R.Transcription.Pcm16_24khz
           ~model:"gpt-live-transcribe" ~turn_detection ()
        |> Result.is_ok))
    cases

let test_oaerr_conversation_event_validation () =
  let module C = R.Conversation in
  let raw =
    C.client_event_to_string
      (C.Input_audio_buffer_commit { event_id = Some "ev-commit" })
  in
  require "commit event id" "\"event_id\":\"ev-commit\"" raw;
  let raw =
    C.client_event_to_string
      (C.Input_audio_buffer_append { audio = audio (); event_id = Some "ev-append" })
  in
  require "append event id" "\"event_id\":\"ev-append\"" raw;
  let raw =
    C.client_event_to_string
      (C.Session_update
         { session = C.session ~model:"gpt-realtime-2" () |> Result.get_ok;
           event_id = Some "ev-session" })
  in
  require "session event id" "\"event_id\":\"ev-session\"" raw

let test_oartt_input_buffer_lifecycle_events () =
  let module T = R.Transcription in
  (match
     T.decode_server_event
       {|{"type":"input_audio_buffer.cleared","event_id":"ev-clear"}|}
   with
   | Ok (T.Input_audio_buffer_cleared { event_id = "ev-clear"; _ }) -> ()
   | _ -> Alcotest.fail "typed cleared event");
  (match
     T.decode_server_event
       {|{"type":"input_audio_buffer.speech_started","event_id":"ev-start"}|}
   with
   | Ok (T.Input_audio_speech_started { event_id = "ev-start"; _ }) -> ()
   | _ -> Alcotest.fail "typed speech started event");
  match
    T.decode_server_event
      {|{"type":"input_audio_buffer.speech_stopped","event_id":"ev-stop"}|}
  with
  | Ok (T.Input_audio_speech_stopped { event_id = "ev-stop"; _ }) -> ()
  | _ -> Alcotest.fail "typed speech stopped event"

let test_oaerr_error_envelope_strictness () =
  let module C = R.Conversation in
  (match C.decode_server_event {|{"type":"error"}|} with
   | Error (C.Decode _) -> ()
   | _ -> Alcotest.fail "missing nested error object must be malformed");
  List.iter
    (fun (label, frame) ->
      match C.decode_server_event frame with
      | Error (C.Decode _) -> ()
      | _ -> Alcotest.fail (label ^ " must be malformed"))
    [
      ("missing nested type",
       {|{"type":"error","event_id":"ev","error":{"code":"c","message":"m"}}|});
      ("numeric nested type",
       {|{"type":"error","event_id":"ev","error":{"type":1,"code":"c","message":"m"}}|});
      ("missing nested message",
       {|{"type":"error","event_id":"ev","error":{"type":"invalid_request_error","code":"c"}}|});
      ("numeric nested message",
       {|{"type":"error","event_id":"ev","error":{"type":"invalid_request_error","code":"c","message":2}}|});
    ];
  (match
     C.decode_server_event
       {|{"type":"error","error":{"code":"c","message":"m"}}|}
   with
   | Error (C.Decode _) -> ()
   | _ -> Alcotest.fail "missing event_id must be malformed");
  let module T = R.Transcription in
  (match
     T.decode_server_event
       {|{"type":"conversation.item.input_audio_transcription.completed","event_id":"ev","item_id":"i","content_index":0,"transcript":"x","languages":{"code":"en"}}|}
   with
   | Error (T.Decode _) -> ()
   | _ -> Alcotest.fail "non-array languages must be malformed");
  match
    T.decode_server_event
      {|{"type":"conversation.item.input_audio_transcription.completed","event_id":"ev","item_id":"i","content_index":0,"transcript":"x","languages":[]}|}
  with
  | Ok (T.Transcription_completed { languages = Some []; _ }) -> ()
  | _ -> Alcotest.fail "genuine empty languages must stay a successful empty list"

let tests =
  [ ("realtime-protocols",
     [ Alcotest.test_case "oartc-tr2e sibling codec contracts" `Quick test_oartc_sibling_codec_contracts;
       Alcotest.test_case "oartt-tff9/unnl/y134/4o8i session full fidelity" `Quick test_oartt_session_full_fidelity;
       Alcotest.test_case "oartt-o19j/nkg1/niot identity languages raw" `Quick test_oartt_event_identity_languages_and_raw;
       Alcotest.test_case "oartt-v2o4 oaerr-koau/noio delta unknown decode" `Quick test_oartt_delta_unknown_and_decode;
       Alcotest.test_case "H1 conversation documented audio event matrix" `Quick test_oartc_documented_audio_event_matrix;
       Alcotest.test_case "H1 transcription noise clear failure formats" `Quick test_oartt_noise_clear_failure_and_formats;
       Alcotest.test_case "M5 malformed shapes languages and literals" `Quick test_m5_malformed_event_shapes_and_languages;
       Alcotest.test_case "oartc conversation session full fidelity" `Quick test_oartc_conversation_session_full_fidelity;
       Alcotest.test_case "oaerr-huch/ivb8/u2k2 conversation session validation" `Quick test_oaerr_conversation_session_validation;
       Alcotest.test_case "oaerr-qb73/8ouo transcription session validation" `Quick test_oaerr_transcription_session_validation;
       Alcotest.test_case "oaerr-qb73 known transcription model matrix" `Quick test_oaerr_transcription_model_matrix;
       Alcotest.test_case "oaerr-huch turn detection numeric class matrix" `Quick test_oaerr_turn_detection_numeric_matrix;
       Alcotest.test_case "oartc conversation client event ids" `Quick test_oaerr_conversation_event_validation;
       Alcotest.test_case "oartt input buffer lifecycle events" `Quick test_oartt_input_buffer_lifecycle_events;
       Alcotest.test_case "oaerr-noio error envelope strictness" `Quick test_oaerr_error_envelope_strictness;
       Alcotest.test_case "oartr-sok5/c2is/g3i5/kmdx client vocabulary" `Quick test_oartr_session_and_client_vocabulary;
       Alcotest.test_case "oartr-8hwa/jews/3j7p typed output unknown" `Quick test_oartr_typed_output_and_unknown ]) ]
