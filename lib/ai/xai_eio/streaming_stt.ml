module E = Eta.Effect
module Json = Eta_ai.Json

type encoding = Pcm | Mulaw | Alaw

type config = {
  sample_rate : int option;
  encoding : encoding option;
  interim_results : bool option;
  endpointing : int option;
  language : string option;
  diarize : bool option;
  filler_words : bool option;
  multichannel : bool option;
  channels : int option;
  keyterm : string list;
  smart_turn : float option;
  smart_turn_timeout : int option;
  vad_threshold : float option;
}

let default_config =
  {
    sample_rate = None;
    encoding = None;
    interim_results = None;
    endpointing = None;
    language = None;
    diarize = None;
    filler_words = None;
    multichannel = None;
    channels = None;
    keyterm = [];
    smart_turn = None;
    smart_turn_timeout = None;
    vad_threshold = None;
  }

let ( let* ) = Result.bind
let invalid message = Error (`Invalid_request message)
let finite value =
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true

let utf8_scalar_count value =
  let rec loop index count =
    if index = String.length value then Ok count
    else
      let decoded = String.get_utf_8_uchar value index in
      if not (Uchar.utf_decode_is_valid decoded) then
        invalid "streaming STT keyterm must be valid UTF-8"
      else
        loop
          (index + Uchar.utf_decode_length decoded)
          (count + 1)
  in
  loop 0 0

let validate config =
  let* () =
    match config.sample_rate with
    | None | Some (8000 | 16000 | 22050 | 24000 | 44100 | 48000) -> Ok ()
    | Some _ ->
        invalid
          "streaming STT sample_rate must be 8000, 16000, 22050, 24000, 44100, or 48000"
  in
  let* () =
    match config.endpointing with
    | None -> Ok ()
    | Some value when value >= 0 && value <= 5000 -> Ok ()
    | Some _ -> invalid "streaming STT endpointing must be between 0 and 5000"
  in
  let* () =
    match config.channels with
    | None -> Ok ()
    | Some value when value >= 1 && value <= 8 -> Ok ()
    | Some _ -> invalid "streaming STT channels must be between 1 and 8"
  in
  let* () =
    match (config.multichannel, config.channels) with
    | Some true, Some channels when channels >= 2 -> Ok ()
    | Some true, _ ->
        invalid "streaming STT multichannel requires channels between 2 and 8"
    | (None | Some false), (None | Some 1) -> Ok ()
    | (None | Some false), Some _ ->
        invalid "streaming STT channels greater than 1 require multichannel=true"
  in
  let* () =
    if List.length config.keyterm > 100 then
      invalid "streaming STT accepts at most 100 keyterm values"
    else
      let rec validate_terms = function
        | [] -> Ok ()
        | term :: rest ->
            let* count = utf8_scalar_count term in
            if count > 50 then
              invalid "streaming STT keyterms must not exceed 50 characters"
            else validate_terms rest
      in
      validate_terms config.keyterm
  in
  let* () =
    match config.smart_turn with
    | Some value when not (finite value) || value < 0. || value > 1. ->
        invalid "streaming STT smart_turn must be between 0 and 1"
    | _ -> Ok ()
  in
  let* () =
    match config.smart_turn_timeout with
    | None -> Ok ()
    | Some value when value >= 1 && value <= 5000 -> Ok ()
    | Some _ ->
        invalid "streaming STT smart_turn_timeout must be between 1 and 5000"
  in
  match config.vad_threshold with
  | Some value when not (finite value) || value < 0. || value > 1. ->
      invalid "streaming STT vad_threshold must be between 0 and 1"
  | _ -> Ok ()

let encoding_string = function Pcm -> "pcm" | Mulaw -> "mulaw" | Alaw -> "alaw"
let option name f = function None -> [] | Some value -> [ (name, f value) ]

let query config =
  option "sample_rate" string_of_int config.sample_rate
  @ option "encoding" encoding_string config.encoding
  @ option "interim_results" Common.bool_string config.interim_results
  @ option "endpointing" string_of_int config.endpointing
  @ option "language" Fun.id config.language
  @ option "diarize" Common.bool_string config.diarize
  @ option "filler_words" Common.bool_string config.filler_words
  @ option "multichannel" Common.bool_string config.multichannel
  @ option "channels" string_of_int config.channels
  @ List.map (fun value -> ("keyterm", value)) config.keyterm
  @ option "smart_turn" Common.float_string config.smart_turn
  @ option "smart_turn_timeout" string_of_int config.smart_turn_timeout
  @ option "vad_threshold" Common.float_string config.vad_threshold

let url ?(endpoint = Eta_ai_xai.Endpoint.default_inference) config =
  let* () = validate config in
  let* base = Common.ws_base_url endpoint in
  Ok (Common.query_url base "/v1/stt" (query config))

type word = {
  text : string;
  start : float option;
  end_ : float option;
  confidence : float option;
  speaker : int option;
  raw : Eta_ai.Json.t;
}

type partial_kind = Interim | Locked | Utterance_final

type partial = {
  text : string;
  words : word list;
  is_final : bool;
  speech_final : bool;
  kind : partial_kind;
  start : float option;
  duration : float option;
  channel_index : int option;
  end_of_turn_confidence : float option;
  raw : Eta_ai.Json.t;
}

type event =
  | Transcript_created of { id : string; raw : Eta_ai.Json.t }
  | Transcript_partial of partial
  | Transcript_done of Eta_ai.Json.t
  | Error of { message : string; raw : Eta_ai.Json.t }
  | Unknown of { type_ : string option; raw : Eta_ai.Json.t }

type error = Common.error

type state =
  | Awaiting_created
  | Open
  | Ending of { mutable remaining_channels : int list }
  | Closed

type t = {
  connection : Common.t;
  pending : bytes Stdlib.Queue.t;
  mutable pending_bytes : int;
  mutable pending_items : int;
  mutable pending_finalize : int option option;
  mutable end_requested : bool;
  expected_done : int;
  mutable state : state;
}

let max_pending_audio_bytes = 1_048_576
let max_pending_audio_items = 1024

let expected_done config =
  match (config.multichannel, config.channels) with
  | Some true, Some channels -> channels
  | _ -> 1

let make config connection =
  {
    connection;
    pending = Stdlib.Queue.create ();
    pending_bytes = 0;
    pending_items = 0;
    pending_finalize = None;
    end_requested = false;
    expected_done = expected_done config;
    state = Awaiting_created;
  }

let encoding_attr config =
  let encoding = Option.value ~default:Pcm config.encoding in
  [ ("gen_ai.request.encoding_formats", encoding_string encoding) ]

let connect ?ca_file ~sw ~net ~api_key config =
  match url config with
  | Error error -> E.fail (error :> Common.error)
  | Ok raw_url ->
      Common.connect ?ca_file ~attrs:(encoding_attr config)
        ~operation:"speech_to_text.streaming" ~sw ~net
        ~headers:(Common.headers api_key) raw_url
      |> E.map (make config)

let connect_on_flow ?key ~sw ~flow ~api_key url config =
  Common.connect_on_flow ?key ~attrs:(encoding_attr config)
    ~operation:"speech_to_text.streaming" ~sw ~flow
    ~headers:(Common.headers api_key) url
  |> E.map (make config)

let send_audio t bytes =
  Common.with_send t.connection @@ fun sender ->
  match t.state with
  | Awaiting_created ->
      if t.end_requested then
        E.fail (`Closed (1000, "streaming STT audio has ended"))
      else if
        t.pending_bytes + Bytes.length bytes > max_pending_audio_bytes
        || t.pending_items >= max_pending_audio_items
      then
        E.fail (`Protocol "streaming STT pre-ready audio limit exceeded")
      else (
        Stdlib.Queue.add (Bytes.copy bytes) t.pending;
        t.pending_bytes <- t.pending_bytes + Bytes.length bytes;
        t.pending_items <- t.pending_items + 1;
        E.unit)
  | Open -> Common.send_binary_locked sender bytes
  | Ending _ | Closed ->
      E.fail (`Closed (1000, "streaming STT audio has ended"))

let control ?field type_ =
  Json.object_
    ([ ("type", Some (Json.string type_)) ]
    @
    match field with
    | None -> []
    | Some (name, value) -> [ (name, Some value) ])
  |> Json.to_string

let finalize ?channel t =
  let valid_channel =
    match channel with
    | None -> true
    | Some value -> value >= 0 && value < t.expected_done
  in
  if not valid_channel then
    E.fail (`Invalid_request "streaming STT finalize channel is out of range")
  else
    Common.with_send t.connection @@ fun sender ->
    match t.state with
    | Awaiting_created ->
        if t.end_requested then
          E.fail (`Closed (1000, "streaming STT audio has ended"))
        else if Option.is_some t.pending_finalize then
          E.fail (`Protocol "streaming STT finalize is already pending")
        else (
          t.pending_finalize <- Some channel;
          E.unit)
    | Open ->
        Common.send_text_locked sender
          (control
             ?field:
               (Option.map (fun value -> ("channel", Json.int value)) channel)
             "finalize")
    | Ending _ | Closed ->
        E.fail (`Closed (1000, "streaming STT audio has ended"))

let send_pending_locked t sender =
  let rec flush () =
    match Stdlib.Queue.take_opt t.pending with
    | None ->
        t.pending_bytes <- 0;
        t.pending_items <- 0;
        E.unit
    | Some bytes ->
        Common.send_binary_locked sender bytes |> E.bind flush
  in
  flush ()

let audio_done t =
  Common.with_send t.connection @@ fun sender ->
  match t.state with
  | Awaiting_created ->
      if t.end_requested then
        E.fail (`Closed (1000, "streaming STT audio has ended"))
      else (
        t.end_requested <- true;
        E.unit)
  | Open ->
      Common.send_text_locked sender (control "audio.done")
      |> E.map (fun () ->
             t.state <-
               Ending
                 {
                   remaining_channels =
                     List.init t.expected_done Fun.id;
                 })
  | Ending _ | Closed ->
      E.fail (`Closed (1000, "streaming STT audio has ended"))

let on_created t =
  Common.with_send t.connection @@ fun sender ->
  match t.state with
  | Open | Ending _ | Closed ->
      E.fail (`Protocol "duplicate transcript.created")
  | Awaiting_created ->
      t.state <- Open;
      send_pending_locked t sender
      |> E.bind (fun () ->
             match t.pending_finalize with
             | None -> E.unit
             | Some channel ->
                 t.pending_finalize <- None;
                 Common.send_text_locked sender
                   (control
                      ?field:
                        (Option.map
                           (fun value -> ("channel", Json.int value))
                           channel)
                      "finalize"))
      |> E.bind (fun () ->
             if t.end_requested then
               Common.send_text_locked sender (control "audio.done")
               |> E.map (fun () ->
                      t.state <-
                        Ending
                          {
                            remaining_channels =
                              List.init t.expected_done Fun.id;
                          })
             else E.unit)

let float_member name json =
  match Json.member name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some (`Intlit value) -> float_of_string_opt value
  | _ -> None

let bool_member name json =
  match Json.member name json with Some (`Bool value) -> Some value | _ -> None

let decode_word json =
  match Json.string_member "text" json with
  | None -> Stdlib.Error (`Decode "transcript word is missing text")
  | Some text ->
      Stdlib.Ok
        {
          text;
          start = float_member "start" json;
          end_ = float_member "end" json;
          confidence = float_member "confidence" json;
          speaker = Json.int_member "speaker" json;
          raw = json;
        }

let rec decode_words acc = function
  | [] -> Stdlib.Ok (List.rev acc)
  | json :: rest -> (
      match decode_word json with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok word -> decode_words (word :: acc) rest)

let decode_partial json =
  match
    ( Json.string_member "text" json,
      bool_member "is_final" json,
      bool_member "speech_final" json )
  with
  | Some text, Some is_final, Some speech_final -> (
      match
        decode_words []
          (Option.value ~default:[] (Json.array_member "words" json))
      with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok _ when not is_final && speech_final ->
          Stdlib.Error
            (`Decode
              "transcript.partial has undocumented is_final=false, speech_final=true")
      | Stdlib.Ok words ->
          let kind =
            if speech_final then Utterance_final
            else if is_final then Locked
            else Interim
          in
          Stdlib.Ok
            (Transcript_partial
               {
                 text;
                 words;
                 is_final;
                 speech_final;
                 kind;
                 start = float_member "start" json;
                 duration = float_member "duration" json;
                 channel_index = Json.int_member "channel_index" json;
                 end_of_turn_confidence =
                   float_member "end_of_turn_confidence" json;
                 raw = json;
               }))
  | _ ->
      Stdlib.Error (`Decode "transcript.partial is missing required fields")

let decode_event raw =
  match Json.parse raw with
  | Stdlib.Error message -> Stdlib.Error (`Decode message)
  | Stdlib.Ok json -> (
      match Json.string_member "type" json with
      | Some "transcript.created" -> (
          match Json.string_member "id" json with
          | Some id -> Stdlib.Ok (Transcript_created { id; raw = json })
          | None ->
              Stdlib.Error (`Decode "transcript.created is missing id"))
      | Some "transcript.partial" -> decode_partial json
      | Some "transcript.done" -> Stdlib.Ok (Transcript_done json)
      | Some "error" -> (
          match Json.string_member "message" json with
          | Some message -> Stdlib.Ok (Error { message; raw = json })
          | None ->
              Stdlib.Error (`Decode "streaming STT error is missing message"))
      | type_ -> Stdlib.Ok (Unknown { type_; raw = json }))

let close_with ?error_type t =
  t.state <- Closed;
  Common.close ?error_type t.connection

let close t = close_with t

let on_done t raw =
  Common.with_send t.connection @@ fun _sender ->
  match t.state with
  | Ending ending ->
      let channel =
        match Json.int_member "channel_index" raw with
        | Some channel -> channel
        | None when t.expected_done = 1 -> 0
        | None -> -1
      in
      if not (List.mem channel ending.remaining_channels) then
        E.fail (`Protocol "duplicate or missing transcript.done channel")
      else
        let remaining =
          List.filter (( <> ) channel) ending.remaining_channels
        in
        if remaining = [] then (
          t.state <- Closed;
          E.pure true)
        else (
          ending.remaining_channels <- remaining;
          E.pure false)
  | Awaiting_created | Open ->
      E.fail (`Protocol "transcript.done arrived before audio.done")
  | Closed -> E.fail (`Closed (1000, "streaming STT is closed"))

let read_event t =
  Common.read_message t.connection
  |> E.bind (function
       | None -> E.pure None
       | Some (`Binary _) ->
           E.fail (`Decode "streaming STT emitted a binary message")
           |> E.finally (close_with ~error_type:"decode_error" t)
       | Some (`Text raw) -> (
           match decode_event raw with
           | Stdlib.Error error ->
               E.fail error
               |> E.finally (close_with ~error_type:"decode_error" t)
           | Stdlib.Ok (Transcript_created { id; _ } as event) ->
               Common.record_attrs t.connection
                 [ ("gen_ai.response.id", id) ];
               on_created t |> E.map (fun () -> Some event)
           | Stdlib.Ok (Transcript_done raw as event) ->
               on_done t raw
               |> E.bind (fun should_close ->
                      (if should_close then Common.close t.connection else E.unit)
                      |> E.map (fun () -> Some event))
           | Stdlib.Ok (Error { message; _ } as event) ->
               Common.record_attrs t.connection
                 [ ("error.type", "provider_error") ];
               ignore message;
               E.pure (Some event)
           | Stdlib.Ok event -> E.pure (Some event)))
