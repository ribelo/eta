module E = Eta.Effect
module Json = Eta_ai.Json

type codec = Mp3 | Wav | Pcm | Mulaw | Alaw

type config = {
  language : string;
  voice : string;
  codec : codec option;
  sample_rate : int option;
  bit_rate : int option;
  speed : float option;
  optimize_streaming_latency : int option;
  text_normalization : bool option;
  with_timestamps : bool option;
}

let ( let* ) = Result.bind
let invalid message = Error (`Invalid_request message)
let finite value =
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true

let validate config =
  let* () =
    if String.trim config.language = "" then
      invalid "streaming TTS language must not be empty"
    else if String.trim config.voice = "" then
      invalid "streaming TTS voice must not be empty"
    else Ok ()
  in
  let* () =
    match config.sample_rate with
    | None | Some (8000 | 16000 | 22050 | 24000 | 44100 | 48000) -> Ok ()
    | Some _ ->
        invalid
          "streaming TTS sample_rate must be 8000, 16000, 22050, 24000, 44100, or 48000"
  in
  let* () =
    match config.bit_rate with
    | None | Some (32000 | 64000 | 96000 | 128000 | 192000) -> Ok ()
    | Some _ ->
        invalid
          "streaming TTS bit_rate must be 32000, 64000, 96000, 128000, or 192000"
  in
  let* () =
    match (config.codec, config.bit_rate) with
    | (None | Some Mp3), _ | _, None -> Ok ()
    | _ -> invalid "streaming TTS bit_rate is valid only for MP3"
  in
  let* () =
    match config.speed with
    | Some value when not (finite value) || value < 0.7 || value > 1.5 ->
        invalid "streaming TTS speed must be between 0.7 and 1.5"
    | _ -> Ok ()
  in
  match config.optimize_streaming_latency with
  | None | Some (0 | 1) -> Ok ()
  | Some _ ->
      invalid "streaming TTS optimize_streaming_latency must be 0 or 1"

let codec_string = function
  | Mp3 -> "mp3"
  | Wav -> "wav"
  | Pcm -> "pcm"
  | Mulaw -> "mulaw"
  | Alaw -> "alaw"

let option name f = function None -> [] | Some value -> [ (name, f value) ]

let query config =
  [ ("language", config.language); ("voice", config.voice) ]
  @ option "codec" codec_string config.codec
  @ option "sample_rate" string_of_int config.sample_rate
  @ option "bit_rate" string_of_int config.bit_rate
  @ option "speed" Common.float_string config.speed
  @ option "optimize_streaming_latency" string_of_int
      config.optimize_streaming_latency
  @ option "text_normalization" Common.bool_string config.text_normalization
  @ option "with_timestamps" Common.bool_string config.with_timestamps

let url ?(endpoint = Eta_ai_xai.Endpoint.default_inference) config =
  let* () = validate config in
  let* base = Common.ws_base_url endpoint in
  Ok (Common.query_url base "/v1/tts" (query config))

type server_error = {
  code : string option;
  type_ : string option;
  message : string option;
  raw : Eta_ai.Json.t;
}

type event =
  | Audio_delta of {
      audio : bytes;
      audio_timestamps : Eta_ai.Json.t option;
      raw : Eta_ai.Json.t;
    }
  | Audio_done of Eta_ai.Json.t
  | Audio_clear of Eta_ai.Json.t
  | Error of server_error
  | Unknown of { type_ : string option; raw : Eta_ai.Json.t }

type error = Common.error
type state = Collecting | Awaiting_audio_done | Closed
type t = {
  connection : Common.t;
  mutable state : state;
}

let make connection = { connection; state = Collecting }

let effective_codec config = Option.value ~default:Mp3 config.codec

let connect ?ca_file ~sw ~net ~api_key config =
  match url config with
  | Error error -> E.fail (error :> Common.error)
  | Ok raw_url ->
      Common.connect ?ca_file
        ~attrs:
          [
            ( "gen_ai.request.encoding_formats",
              codec_string (effective_codec config) );
          ]
        ~operation:"text_to_speech.streaming" ~sw ~net
        ~headers:(Common.headers api_key) raw_url
      |> E.map make

let connect_on_flow ?key ~sw ~flow ~api_key url config =
  Common.connect_on_flow ?key
    ~attrs:
      [
        ("gen_ai.request.encoding_formats", codec_string (effective_codec config));
      ]
    ~operation:"text_to_speech.streaming" ~sw ~flow
    ~headers:(Common.headers api_key) url
  |> E.map make

let utf8_scalar_count value =
  let rec loop index count =
    if index = String.length value then Ok count
    else
      let decoded = String.get_utf_8_uchar value index in
      if not (Uchar.utf_decode_is_valid decoded) then
        Error (`Invalid_request "text.delta must be valid UTF-8")
      else
        loop
          (index + Uchar.utf_decode_length decoded)
          (count + 1)
  in
  loop 0 0

let message fields = Json.object_ fields |> Json.to_string

let text_delta t delta =
  match utf8_scalar_count delta with
  | Error error -> E.fail error
  | Ok count when count > 15_000 ->
      E.fail (`Invalid_request "text.delta must not exceed 15000 characters")
  | Ok _ ->
      Common.with_send t.connection @@ fun sender ->
      match t.state with
      | Collecting ->
          Common.send_text_locked sender
            (message
               [
                 ("type", Some (Json.string "text.delta"));
                 ("delta", Some (Json.string delta));
               ])
      | Awaiting_audio_done ->
          E.fail (`Protocol "text.delta requires the preceding audio.done")
      | Closed -> E.fail (`Closed (1000, "streaming TTS is closed"))

let text_done t =
  Common.with_send t.connection @@ fun sender ->
  match t.state with
  | Collecting ->
      Common.send_text_locked sender
        (message [ ("type", Some (Json.string "text.done")) ])
      |> E.map (fun () -> t.state <- Awaiting_audio_done)
  | Awaiting_audio_done ->
      E.fail (`Protocol "text.done is already awaiting audio.done")
  | Closed -> E.fail (`Closed (1000, "streaming TTS is closed"))

let text_clear t =
  Common.with_send t.connection @@ fun sender ->
  match t.state with
  | Collecting ->
      Common.send_text_locked sender
        (message [ ("type", Some (Json.string "text.clear")) ])
  | Awaiting_audio_done ->
      E.fail (`Protocol "text.clear requires the preceding audio.done")
  | Closed -> E.fail (`Closed (1000, "streaming TTS is closed"))

let decode_base64 value =
  try Stdlib.Ok (Bytes.of_string (Base64.decode_exn ~pad:true value))
  with _ -> Stdlib.Error (`Decode "invalid base64 streaming TTS audio")

let decode_event raw =
  match Json.parse raw with
  | Stdlib.Error message -> Stdlib.Error (`Decode message)
  | Stdlib.Ok json -> (
      match Json.string_member "type" json with
      | Some "audio.delta" -> (
          match Json.string_member "delta" json with
          | None -> Stdlib.Error (`Decode "audio.delta is missing delta")
          | Some delta ->
              let* audio = decode_base64 delta in
              let audio_timestamps = Json.member "audio_timestamps" json in
              Stdlib.Ok (Audio_delta { audio; audio_timestamps; raw = json }))
      | Some "audio.done" -> Stdlib.Ok (Audio_done json)
      | Some "audio.clear" -> Stdlib.Ok (Audio_clear json)
      | Some "error" ->
          let payload =
            Option.value ~default:json (Json.object_member "error" json)
          in
          Stdlib.Ok
            (Error
               {
                 code = Json.scalar_string_member "code" payload;
                 type_ = Json.scalar_string_member "type" payload;
                 message = Json.scalar_string_member "message" payload;
                 raw = json;
               })
      | type_ -> Stdlib.Ok (Unknown { type_; raw = json }))

let close_with ?error_type t =
  t.state <- Closed;
  Common.close ?error_type t.connection

let close t = close_with t

let on_audio_done t =
  Common.with_send t.connection @@ fun _sender ->
  match t.state with
  | Awaiting_audio_done ->
      t.state <- Collecting;
      E.unit
  | Collecting ->
      E.fail (`Protocol "audio.done arrived without text.done")
  | Closed -> E.fail (`Closed (1000, "streaming TTS is closed"))

let read_event t =
  Common.read_message t.connection
  |> E.bind (function
       | None -> E.pure None
       | Some (`Binary _) ->
           E.fail (`Decode "streaming TTS emitted a binary message")
           |> E.finally (close_with ~error_type:"decode_error" t)
       | Some (`Text raw) -> (
           match decode_event raw with
           | Stdlib.Ok (Audio_done _ as event) ->
               on_audio_done t |> E.map (fun () -> Some event)
           | Stdlib.Ok (Error error as event) ->
               let error_type =
                 Option.value ~default:"provider_error"
                   (match error.code with
                   | Some _ as code -> code
                   | None -> error.type_)
               in
               Common.record_attrs t.connection
                 [ ("error.type", error_type) ];
               E.pure (Some event)
           | Stdlib.Ok event -> E.pure (Some event)
           | Stdlib.Error error ->
               E.fail error
               |> E.finally (close_with ~error_type:"decode_error" t)))
