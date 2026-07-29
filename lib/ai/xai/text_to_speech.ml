module A = Eta_ai
module E = Eta.Effect
module Json = A.Json
module C = Common

let ( let* ) = Result.bind

type codec = Mp3 | Wav | Pcm | Mulaw | Alaw

type output_format = {
  codec : codec;
  sample_rate : int option;
  bit_rate : int option;
}

type request = {
  text : string;
  language : string;
  voice_id : string option;
  output_format : output_format option;
  speed : float option;
  optimize_streaming_latency : int option;
  text_normalization : bool option;
  with_timestamps : bool;
}

type raw_audio = {
  content_type : string option;
  bytes : bytes;
}

type timestamped_audio = {
  audio : bytes;
  content_type : string option;
  duration : float option;
  graph_chars : string list;
  graph_times : A.Json.t;
  raw : A.raw_json;
}

type response =
  | Raw_audio of raw_audio
  | Timestamped_audio of timestamped_audio

let sample_rates = [ 8000; 16000; 22050; 24000; 44100; 48000 ]
let bit_rates = [ 32000; 64000; 96000; 128000; 192000 ]
let response_max_bytes = 128 * 1024 * 1024

let codec_string = function
  | Mp3 -> "mp3"
  | Wav -> "wav"
  | Pcm -> "pcm"
  | Mulaw -> "mulaw"
  | Alaw -> "alaw"

let validate request =
  let* text_length = C.utf8_scalar_count "text-to-speech text" request.text in
  let* () =
    if text_length > 15_000 then
      C.invalid "unary text-to-speech text exceeds 15000 characters"
    else if String.trim request.language = "" then
      C.invalid "text-to-speech language must not be empty"
    else Ok ()
  in
  let* () =
    match request.optimize_streaming_latency with
    | None | Some 0 | Some 1 -> Ok ()
    | Some _ ->
        C.invalid "optimize_streaming_latency must be level 0 or level 1"
  in
  let* () =
    match request.speed with
    | None -> Ok ()
    | Some value ->
        let* value = C.finite_float "speed" value in
        if value < 0.7 || value > 1.5 then
          C.invalid "text-to-speech speed must be between 0.7 and 1.5"
        else Ok ()
  in
  match request.output_format with
  | None -> Ok ()
  | Some output ->
      let* () =
        match output.sample_rate with
        | None -> Ok ()
        | Some rate when List.mem rate sample_rates -> Ok ()
        | Some _ ->
            C.invalid
              "text-to-speech sample_rate must be 8000, 16000, 22050, 24000, 44100, or 48000"
      in
      match (output.codec, output.bit_rate) with
      | Mp3, None -> Ok ()
      | Mp3, Some rate when List.mem rate bit_rates -> Ok ()
      | Mp3, Some _ ->
          C.invalid
            "MP3 bit_rate must be 32000, 64000, 96000, 128000, or 192000"
      | (Wav | Pcm | Mulaw | Alaw), None -> Ok ()
      | (Wav | Pcm | Mulaw | Alaw), Some _ ->
          C.invalid "bit_rate is supported only for MP3"

let output_format_json output =
  Json.object_
    [
      ("codec", Some (Json.string (codec_string output.codec)));
      ("sample_rate", Option.map Json.int output.sample_rate);
      ("bit_rate", Option.map Json.int output.bit_rate);
    ]

let request ?(endpoint = Endpoint.default_inference) ~api_key request =
  let* () = validate request in
  let* speed =
    match request.speed with
    | None -> Ok None
    | Some value ->
        let* _ = C.finite_float "speed" value in
        Ok (Json.float value)
  in
  let json =
    Json.object_
      [
        ("text", Some (Json.string request.text));
        ("language", Some (Json.string request.language));
        ("voice_id", Option.map Json.string request.voice_id);
        ("output_format", Option.map output_format_json request.output_format);
        ("speed", speed);
        ( "optimize_streaming_latency",
          Option.map Json.int request.optimize_streaming_latency );
        ("text_normalization", Option.map Json.bool request.text_normalization);
        ("with_timestamps", Some (Json.bool request.with_timestamps));
      ]
  in
  let base_url = Endpoint.inference_base_url endpoint in
  Ok
    (C.json_request ~headers:(C.inference_headers api_key) ~base_url ~meth:"POST"
       ~path:"/v1/tts" ~json ())

let decode_base64 raw =
  try Ok (Bytes.of_string (Base64.decode_exn ~pad:true raw))
  with _ -> C.decode_error "timestamped TTS audio is not valid base64"

let decode_timestamped raw =
  let* json = C.parse_json raw in
  let* encoded = C.required_string "audio" json in
  let* audio = decode_base64 encoded in
  let timestamps = Json.object_member "audio_timestamps" json in
  let graph_chars =
    Option.bind timestamps (Json.array_member "graph_chars")
    |> Option.value ~default:[]
    |> List.filter_map (function `String value -> Some value | _ -> None)
  in
  let graph_times =
    Option.bind timestamps (Json.member "graph_times")
    |> Option.value ~default:`Null
  in
  Ok
    (Timestamped_audio
       {
         audio;
         content_type = Json.string_member "content_type" json;
         duration = C.float_member "duration" json;
         graph_chars;
         graph_times;
         raw;
       })

let synthesize ?(endpoint = Endpoint.default_inference) client ~api_key
    request_value =
  let base_url = Endpoint.inference_base_url endpoint in
  match request ~endpoint ~api_key request_value with
  | Error error -> E.fail error
  | Ok http_request ->
      C.perform_response ~max_bytes:response_max_bytes ~base_url
        ~operation:"text_to_speech"
        ~attrs:
          (match request_value.output_format with
          | None -> []
          | Some output ->
              [ ("gen_ai.request.encoding_formats", codec_string output.codec) ])
        client http_request
      |> E.bind (fun (bytes, headers) ->
             if request_value.with_timestamps then
               match decode_timestamped (Bytes.to_string bytes) with
               | Ok response -> E.pure response
               | Error error -> E.fail error
             else
               E.pure
                 (Raw_audio
                    { content_type = C.content_type headers; bytes }))
