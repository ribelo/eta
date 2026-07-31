(** OpenAI Speech API ([POST /v1/audio/speech]). *)

module A = Common.A
module E = Eta.Effect
module H = Common.H
module Json = A.Json

let ( let* ) = Result.bind

module Voices = struct
  type custom_id = string

  type built_in =
    | Alloy
    | Ash
    | Ballad
    | Coral
    | Echo
    | Fable
    | Onyx
    | Nova
    | Sage
    | Shimmer
    | Verse
    | Marin
    | Cedar
    | Other of string

  type t = Built_in of built_in | Custom of custom_id

  let custom_id value =
    if A.Json_helpers.is_blank value then
      Common.invalid_request "custom voice ID must not be empty"
    else Ok value

  let built_in_to_string = function
    | Alloy -> "alloy"
    | Ash -> "ash"
    | Ballad -> "ballad"
    | Coral -> "coral"
    | Echo -> "echo"
    | Fable -> "fable"
    | Onyx -> "onyx"
    | Nova -> "nova"
    | Sage -> "sage"
    | Shimmer -> "shimmer"
    | Verse -> "verse"
    | Marin -> "marin"
    | Cedar -> "cedar"
    | Other value -> value

  let of_string = function
    | "alloy" -> Built_in Alloy
    | "ash" -> Built_in Ash
    | "ballad" -> Built_in Ballad
    | "coral" -> Built_in Coral
    | "echo" -> Built_in Echo
    | "fable" -> Built_in Fable
    | "onyx" -> Built_in Onyx
    | "nova" -> Built_in Nova
    | "sage" -> Built_in Sage
    | "shimmer" -> Built_in Shimmer
    | "verse" -> Built_in Verse
    | "marin" -> Built_in Marin
    | "cedar" -> Built_in Cedar
    | value -> Built_in (Other value)

  let to_json = function
    | Built_in voice -> Json.string (built_in_to_string voice)
    | Custom id -> Json.object_ [ ("id", Some (Json.string id)) ]

  let validate = function
    | Built_in voice when A.Json_helpers.is_blank (built_in_to_string voice) ->
        Common.invalid_request "built-in voice must not be empty"
    | Custom id when A.Json_helpers.is_blank id ->
        Common.invalid_request "custom voice ID must not be empty"
    | Built_in _ | Custom _ -> Ok ()
end

type model =
  | Tts_1
  | Tts_1_hd
  | Gpt_4o_mini_tts
  | Gpt_4o_mini_tts_2025_12_15
  | Other of string

type response_format = Mp3 | Opus | Aac | Flac | Wav | Pcm
type stream_format = Audio | Sse

type request = {
  model : model;
  input : string;
  voice : Voices.t;
  instructions : string option;
  response_format : response_format option;
  speed : float option;
  stream_format : stream_format option;
  extra : (string * A.Json.t) list;
}

type result = {
  content_type : string option;
  audio : bytes;
}

type event =
  | Unknown of {
      type_ : string;
      raw : A.Json.t;
    }

type configuration = {
  model : model;
  instructions : string option;
  extra : (string * A.Json.t) list;
}

type request_construction = A.Audio.Text_to_speech.request

let model_to_string = function
  | Tts_1 -> "tts-1"
  | Tts_1_hd -> "tts-1-hd"
  | Gpt_4o_mini_tts -> "gpt-4o-mini-tts"
  | Gpt_4o_mini_tts_2025_12_15 -> "gpt-4o-mini-tts-2025-12-15"
  | Other value -> value

let response_format_to_string = function
  | Mp3 -> "mp3"
  | Opus -> "opus"
  | Aac -> "aac"
  | Flac -> "flac"
  | Wav -> "wav"
  | Pcm -> "pcm"

let stream_format_to_string = function Audio -> "audio" | Sse -> "sse"
let known_legacy_model model =
  match model_to_string model with "tts-1" | "tts-1-hd" -> true | _ -> false

let utf8_length value =
  let len = String.length value in
  let continuation index =
    index < len
    &&
    let byte = Char.code value.[index] in
    byte land 0xc0 = 0x80
  in
  let rec loop index count =
    if index = len then Ok count
    else
      let byte = Char.code value.[index] in
      if byte land 0x80 = 0 then loop (index + 1) (count + 1)
      else if byte >= 0xc2 && byte <= 0xdf && continuation (index + 1) then
        loop (index + 2) (count + 1)
      else if
        byte >= 0xe0 && byte <= 0xef
        && continuation (index + 1)
        && continuation (index + 2)
        &&
        let second = Char.code value.[index + 1] in
        (byte <> 0xe0 || second >= 0xa0) && (byte <> 0xed || second < 0xa0)
      then loop (index + 3) (count + 1)
      else if
        byte >= 0xf0 && byte <= 0xf4
        && continuation (index + 1)
        && continuation (index + 2)
        && continuation (index + 3)
        &&
        let second = Char.code value.[index + 1] in
        (byte <> 0xf0 || second >= 0x90) && (byte <> 0xf4 || second < 0x90)
      then loop (index + 4) (count + 1)
      else Error ()
  in
  loop 0 0

let owned_fields =
  [
    "model";
    "input";
    "voice";
    "instructions";
    "response_format";
    "speed";
    "stream_format";
  ]

let validate_extra extra =
  match
    List.find_opt
      (fun (name, _) -> List.exists (String.equal name) owned_fields)
      extra
  with
  | Some (name, _) ->
      Common.invalid_request ("extra field collides with owned field " ^ name)
  | None -> Ok ()

let validate (request : request) =
  if A.Json_helpers.is_blank (model_to_string request.model) then
    Common.invalid_request "speech model must not be empty"
  else
    let* input_length =
      match utf8_length request.input with
      | Ok length -> Ok length
      | Error () -> Common.invalid_request "speech input must be valid UTF-8"
    in
    if input_length = 0 then
      Common.invalid_request "speech input must not be empty"
    else if input_length > 4096 then
      Common.invalid_request "speech input must not exceed 4096 characters"
    else
      let* () = Voices.validate request.voice in
      let* () =
        match request.instructions with
        | None -> Ok ()
        | Some instructions -> (
            match utf8_length instructions with
            | Error () ->
                Common.invalid_request
                  "speech instructions must be valid UTF-8"
            | Ok length when length > 4096 ->
                Common.invalid_request
                  "speech instructions must not exceed 4096 characters"
            | Ok _ -> Ok ())
      in
      let* () =
        match request.speed with
        | Some speed
          when (not (Float.is_finite speed)) || speed < 0.25 || speed > 4.0 ->
            Common.invalid_request
              "speech speed must be finite and between 0.25 and 4.0"
        | None | Some _ -> Ok ()
      in
      let* () =
        if known_legacy_model request.model && Option.is_some request.instructions
        then
          Common.invalid_request
            "speech instructions are not supported for tts-1 or tts-1-hd"
        else Ok ()
      in
      let* () =
        if
          known_legacy_model request.model
          && request.stream_format = Some Sse
        then
          Common.invalid_request
            "speech SSE is not supported for tts-1 or tts-1-hd"
        else Ok ()
      in
      let* () =
        if known_legacy_model request.model then
          let voice =
            match request.voice with
            | Voices.Built_in voice -> Some (Voices.built_in_to_string voice)
            | Voices.Custom _ -> None
          in
          match voice with
          | Some
              ( "ballad" | "verse" | "marin" | "cedar" ) ->
              Common.invalid_request
                "selected voice is not supported for tts-1 or tts-1-hd"
          | Some _ | None -> Ok ()
        else Ok ()
      in
      validate_extra request.extra

let request ~model ~input ~voice ?instructions ?response_format ?speed
    ?stream_format ?(extra = []) () =
  let request =
    {
      model;
      input;
      voice;
      instructions;
      response_format;
      speed;
      stream_format;
      extra;
    }
  in
  Result.map (fun () -> request) (validate request)

let of_eta_ai request = request

let neutral_response_format = function
  | A.Audio.Text_to_speech.Mp3 -> Mp3
  | Wav -> Wav
  | Pcm -> Pcm

let configure configuration (construction : request_construction) =
  request ~model:configuration.model ~input:construction.text
    ~voice:(Voices.of_string construction.voice)
    ?response_format:(Option.map neutral_response_format construction.encoding)
    ?speed:construction.speed ?instructions:configuration.instructions
    ~extra:configuration.extra ()

let to_eta_ai (result : result) : A.Audio.Text_to_speech.result =
  { content_type = result.content_type; audio = result.audio }

let encode request =
  let* () = validate request in
  Ok
    (Common.with_json_fields request.extra
       [
         ("model", Some (Json.string (model_to_string request.model)));
         ("input", Some (Json.string request.input));
         ("voice", Some (Voices.to_json request.voice));
         ("instructions", Option.map Json.string request.instructions);
         ( "response_format",
           Option.map
             (fun format -> Json.string (response_format_to_string format))
             request.response_format );
         ("speed", Option.bind request.speed Json.float);
         ( "stream_format",
           Option.map
             (fun format -> Json.string (stream_format_to_string format))
             request.stream_format );
       ]
    |> Json.to_string)

let decode_response (body, headers) =
  {
    content_type = H.Core.Header.get "content-type" headers;
    audio = body;
  }

let http_request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  match encode request with
  | Error _ as error -> error
  | Ok raw ->
      let headers =
        provider.A.auth_headers api_key |> H.Core.Header.remove "accept"
      in
      Ok
        (H.Request.make ~headers
           ~body:(H.Request.Fixed [ Bytes.of_string raw ])
           "POST"
           (Common.join_url provider.base_url "/v1/audio/speech"))

let operation_mismatch (request : request) expected =
  match request.stream_format, expected with
  | Some Sse, `Audio ->
      Common.invalid_request
        "stream_format=sse requires the stream_events operation"
  | (None | Some Audio), `Events ->
      Common.invalid_request "stream_events requires stream_format=sse"
  | (None | Some Audio), `Audio | Some Sse, `Events -> Ok ()

let defer thunk = E.sync thunk |> E.bind Fun.id

let create ?provider:custom_provider client ~api_key
    (speech_request : request) =
  let provider = Common.default_provider Common.provider custom_provider in
  let model = model_to_string speech_request.model in
  (match operation_mismatch speech_request `Audio with
  | Error error -> E.fail error
  | Ok () ->
      defer (fun () ->
          Common.run_binary ~max_bytes:max_int provider client
            (http_request ~provider ~api_key speech_request)
            decode_response))
  |> Common.with_provider_span provider ~operation:"speech.create" ~model

type audio_stream = {
  audio_provider : A.provider;
  audio_model : string;
  audio_body : H.Body.Stream.t;
  audio_released : bool Atomic.t;
  audio_active : bool Atomic.t;
}

let audio_attrs = [ ("eta_ai.request.stream_format", "audio") ]

let release_audio stream =
  E.uninterruptible
    (E.sync (fun () ->
         Atomic.compare_and_set stream.audio_released false true)
    |> E.bind (fun release ->
           if release then
             defer (fun () -> H.Body.Stream.discard stream.audio_body)
             |> E.map_error (fun error -> Openai_error.Http error)
           else E.unit))

let with_audio_operation stream operation thunk =
  (E.sync (fun () ->
       Atomic.compare_and_set stream.audio_active false true)
  |> E.bind (fun acquired ->
         if not acquired then E.fail (Openai_error.Concurrent_use "speech audio")
         else
           defer thunk
           |> E.finally
                (E.sync (fun () -> Atomic.set stream.audio_active false))))
  |> Common.with_provider_span stream.audio_provider ~operation
       ~model:stream.audio_model ~attrs:audio_attrs

let read_audio_unlocked stream =
  defer (fun () -> H.Body.Stream.read stream.audio_body)
  |> E.map_error (fun error -> Openai_error.Http error)
  |> E.on_exit (function
       | Eta.Exit.Ok None -> release_audio stream
       | Eta.Exit.Ok (Some _) -> E.unit
       | Eta.Exit.Error _ -> release_audio stream)

let read_audio stream =
  with_audio_operation stream "speech.read_audio" (fun () ->
      read_audio_unlocked stream)

let close_audio stream =
  with_audio_operation stream "speech.close_audio" (fun () ->
      release_audio stream)

let collect_audio ~max_bytes stream =
  with_audio_operation stream "speech.collect_audio" (fun () ->
      if max_bytes < 0 then
        E.fail (Openai_error.Invalid_request "max_bytes must not be negative")
        |> E.finally (release_audio stream)
      else
        let rec loop chunks total =
          read_audio_unlocked stream
          |> E.bind (function
               | None ->
                   E.sync (fun () ->
                       let output = Bytes.create total in
                       ignore
                         (List.fold_left
                            (fun offset chunk ->
                              let length = Bytes.length chunk in
                              Bytes.blit chunk 0 output offset length;
                              offset + length)
                            0 (List.rev chunks));
                       output)
               | Some chunk ->
                   let chunk_length = Bytes.length chunk in
                   (match
                     Collector_math.checked_total ~max_bytes ~total
                       ~chunk_length
                   with
                   | Error actual ->
                     E.fail
                       (Openai_error.Limit_exceeded
                          {
                            kind = "speech audio bytes";
                            limit = max_bytes;
                            actual;
                          })
                     |> E.finally (release_audio stream)
                   | Ok total -> loop (chunk :: chunks) total))
        in
        loop [] 0)

let perform_stream client request make =
  defer (fun () -> H.request client request)
  |> A.suppress_provider_transport_observability
  |> E.map_error (fun error -> Openai_error.Http error)
  |> E.bind (fun (response : H.Response.t) ->
         if response.status >= 200 && response.status < 300 then
           E.sync (fun () -> make response.body)
           |> E.on_exit (function
                | Eta.Exit.Ok _ -> E.unit
                | Eta.Exit.Error _ ->
                    defer (fun () -> H.Body.Stream.discard response.body)
                    |> E.map_error (fun error -> Openai_error.Http error))
         else
           Common.read_body ~max_bytes:max_int response.body
           |> E.bind (fun body ->
                  E.fail
                    (Openai_error.decode ~status:response.status
                       ~headers:response.headers (Bytes.to_string body))))

let stream_audio ?provider:custom_provider client ~api_key
    (speech_request : request) =
  let provider = Common.default_provider Common.provider custom_provider in
  let model = model_to_string speech_request.model in
  (match operation_mismatch speech_request `Audio with
  | Error error -> E.fail error
  | Ok () ->
      Common.run_request
        (http_request ~provider ~api_key speech_request)
        (fun request ->
          perform_stream client request (fun audio_body ->
              {
                audio_provider = provider;
                audio_model = model;
                audio_body;
                audio_released = Atomic.make false;
                audio_active = Atomic.make false;
              })))
  |> Common.with_provider_span provider ~operation:"speech.stream_audio" ~model
       ~attrs:audio_attrs

let default_max_buffer_bytes = 1024 * 1024
let default_max_json_bytes = 1024 * 1024
let default_max_pending_events = 256

type bom_state = Start | Ef | Ef_bb | Bom_done

type event_stream = {
  event_provider : A.provider;
  event_model : string;
  event_body : H.Body.Stream.t;
  max_buffer_bytes : int;
  max_json_bytes : int;
  max_pending_events : int;
  line : bytes;
  data : bytes;
  mutable line_length : int;
  mutable data_length : int;
  mutable framing_bytes : int;
  mutable has_data : bool;
  mutable after_cr : bool;
  mutable bom_state : bom_state;
  mutable event_pending : event list;
  mutable event_eof : bool;
  event_released : bool Atomic.t;
  event_active : bool Atomic.t;
}

let event_attrs = [ ("eta_ai.request.stream_format", "sse") ]

let event_limit kind limit actual =
  Openai_error.Limit_exceeded { kind; limit; actual }

let over_limit_actual limit = if limit = max_int then max_int else limit + 1

let clear_parser stream =
  stream.line_length <- 0;
  stream.data_length <- 0;
  stream.framing_bytes <- 0;
  stream.has_data <- false;
  stream.after_cr <- false;
  stream.event_pending <- [];
  stream.event_eof <- true

let release_events stream =
  E.uninterruptible
    (E.sync (fun () ->
         Atomic.compare_and_set stream.event_released false true)
    |> E.bind (fun release ->
           if release then
             defer (fun () -> H.Body.Stream.discard stream.event_body)
             |> E.map_error (fun error -> Openai_error.Http error)
           else E.unit))

let cleanup_events stream =
  E.uninterruptible
    (E.sync (fun () -> clear_parser stream)
    |> E.bind (fun () -> release_events stream))

let with_event_operation stream operation thunk =
  (E.sync (fun () ->
       Atomic.compare_and_set stream.event_active false true)
  |> E.bind (fun acquired ->
         if not acquired then E.fail (Openai_error.Concurrent_use "speech SSE")
         else
           defer thunk
           |> E.finally
                (E.sync (fun () -> Atomic.set stream.event_active false))))
  |> Common.with_provider_span stream.event_provider ~operation
       ~model:stream.event_model ~attrs:event_attrs

let line_is_data stream colon =
  let field_length = Option.value colon ~default:stream.line_length in
  field_length = 4
  && Bytes.get stream.line 0 = 'd'
  && Bytes.get stream.line 1 = 'a'
  && Bytes.get stream.line 2 = 't'
  && Bytes.get stream.line 3 = 'a'

let append_data_byte stream byte =
  if stream.data_length >= stream.max_json_bytes then
    Error
      (event_limit "speech SSE JSON bytes" stream.max_json_bytes
         (over_limit_actual stream.max_json_bytes))
  else begin
    Bytes.set stream.data stream.data_length byte;
    stream.data_length <- stream.data_length + 1;
    Ok ()
  end

let parse_line stream =
  if stream.line_length = 0 || Bytes.get stream.line 0 = ':' then Ok ()
  else
    let rec find_colon index =
      if index = stream.line_length then None
      else if Bytes.get stream.line index = ':' then Some index
      else find_colon (index + 1)
    in
    let colon = find_colon 0 in
    if not (line_is_data stream colon) then Ok ()
    else
      let* () =
        if stream.has_data then append_data_byte stream '\n' else Ok ()
      in
      stream.has_data <- true;
      let start =
        match colon with
        | None -> stream.line_length
        | Some colon ->
            let start = colon + 1 in
            if
              start < stream.line_length
              && Bytes.get stream.line start = ' '
            then start + 1
            else start
      in
      let rec copy index =
        if index = stream.line_length then Ok ()
        else
          let* () = append_data_byte stream (Bytes.get stream.line index) in
          copy (index + 1)
      in
      copy start

let decode_event stream =
  let raw = Bytes.sub_string stream.data 0 stream.data_length in
  match Json.parse raw with
  | Error message ->
      Error (Openai_error.Decode { message; raw_body = Some raw })
  | Ok json -> (
      match json with
      | `Assoc _ -> (
          match Json.string_member "type" json with
          | Some type_ -> Ok (Unknown { type_; raw = json })
          | None ->
              Error
                (Openai_error.Decode
                   {
                     message =
                       "speech SSE event must contain a string type field";
                     raw_body = Some raw;
                   }))
      | _ ->
          Error
            (Openai_error.Decode
               {
                 message = "speech SSE event must be a JSON object";
                 raw_body = Some raw;
               }))

let reset_event stream =
  stream.line_length <- 0;
  stream.data_length <- 0;
  stream.framing_bytes <- 0;
  stream.has_data <- false

let dispatch_event stream =
  if not stream.has_data then begin
    reset_event stream;
    Ok ()
  end
  else
    let pending = List.length stream.event_pending in
    if pending >= stream.max_pending_events then
      Error
        (event_limit "speech SSE pending events" stream.max_pending_events
           (over_limit_actual stream.max_pending_events))
    else
      let* event = decode_event stream in
      stream.event_pending <- stream.event_pending @ [ event ];
      reset_event stream;
      Ok ()

let finish_line stream =
  let result =
    if stream.line_length = 0 then dispatch_event stream
    else parse_line stream
  in
  stream.line_length <- 0;
  result

let append_line_byte stream byte =
  if stream.framing_bytes >= stream.max_buffer_bytes then
    Error
      (event_limit "speech SSE unframed bytes" stream.max_buffer_bytes
         (over_limit_actual stream.max_buffer_bytes))
  else begin
    Bytes.set stream.line stream.line_length byte;
    stream.line_length <- stream.line_length + 1;
    stream.framing_bytes <- stream.framing_bytes + 1;
    Ok ()
  end

let rec process_content_byte stream byte =
  if stream.after_cr then begin
    stream.after_cr <- false;
    if byte = '\n' then Ok () else process_content_byte stream byte
  end
  else
    match byte with
    | '\r' ->
        stream.after_cr <- true;
        finish_line stream
    | '\n' -> finish_line stream
    | byte -> append_line_byte stream byte

let process_byte stream byte =
  match stream.bom_state with
  | Bom_done -> process_content_byte stream byte
  | Start ->
      if Char.code byte = 0xef then begin
        stream.bom_state <- Ef;
        Ok ()
      end
      else begin
        stream.bom_state <- Bom_done;
        process_content_byte stream byte
      end
  | Ef ->
      if Char.code byte = 0xbb then begin
        stream.bom_state <- Ef_bb;
        Ok ()
      end
      else begin
        stream.bom_state <- Bom_done;
        let* () = process_content_byte stream (Char.chr 0xef) in
        process_content_byte stream byte
      end
  | Ef_bb ->
      stream.bom_state <- Bom_done;
      if Char.code byte = 0xbf then Ok ()
      else
        let* () = process_content_byte stream (Char.chr 0xef) in
        let* () = process_content_byte stream (Char.chr 0xbb) in
        process_content_byte stream byte

let feed_chunk stream chunk =
  let length = Bytes.length chunk in
  let rec loop index =
    if index = length then Ok ()
    else
      let* () = process_byte stream (Bytes.get chunk index) in
      loop (index + 1)
  in
  loop 0

let rec read_event_step stream =
  match stream.event_pending with
  | event :: rest ->
      E.sync (fun () ->
          stream.event_pending <- rest;
          Some event)
  | [] when stream.event_eof -> E.pure None
  | [] ->
      defer (fun () -> H.Body.Stream.read stream.event_body)
      |> E.map_error (fun error -> Openai_error.Http error)
      |> E.bind (function
           | None ->
               E.sync (fun () ->
                   stream.event_eof <- true;
                   (* WHATWG discards an incomplete event at EOF. *)
                   clear_parser stream)
               |> E.bind (fun () ->
                      release_events stream |> E.map (fun () -> None))
           | Some bytes ->
               E.sync (fun () -> feed_chunk stream bytes)
               |> E.bind (function
                    | Error error -> E.fail error
                    | Ok () -> read_event_step stream))

let read_event_unlocked stream =
  read_event_step stream
  |> E.on_exit (function
       | Eta.Exit.Ok _ -> E.unit
       | Eta.Exit.Error _ -> cleanup_events stream)

let read_event stream =
  with_event_operation stream "speech.read_event" (fun () ->
      read_event_unlocked stream)

let close_events stream =
  with_event_operation stream "speech.close_events" (fun () ->
      cleanup_events stream)

let allocate_event_storage ~max_buffer_bytes ~max_json_bytes =
  E.sync (fun () ->
      if
        max_buffer_bytes > Sys.max_string_length
        || max_json_bytes > Sys.max_string_length
      then
        Error
          (Openai_error.Invalid_request
             "speech SSE byte bounds exceed the platform allocation limit")
      else
        try Ok (Bytes.create max_buffer_bytes, Bytes.create max_json_bytes)
        with
        | Out_of_memory | Invalid_argument _ ->
            Error
              (Openai_error.Invalid_request
                 "speech SSE parser storage cannot be allocated"))
  |> E.bind (function Ok storage -> E.pure storage | Error error -> E.fail error)

let stream_events ?(max_buffer_bytes = default_max_buffer_bytes)
    ?(max_json_bytes = default_max_json_bytes)
    ?(max_pending_events = default_max_pending_events) ?provider:custom_provider
    client ~api_key (speech_request : request) =
  let provider = Common.default_provider Common.provider custom_provider in
  let model = model_to_string speech_request.model in
  (if max_buffer_bytes <= 0 || max_json_bytes <= 0 || max_pending_events <= 0 then
     E.fail
       (Openai_error.Invalid_request
          "speech SSE bounds must all be positive")
   else
     match operation_mismatch speech_request `Events with
     | Error error -> E.fail error
     | Ok () ->
         allocate_event_storage ~max_buffer_bytes ~max_json_bytes
         |> E.bind (fun (line, data) ->
                Common.run_request
                  (http_request ~provider ~api_key speech_request)
                  (fun request ->
                    perform_stream client request (fun event_body ->
                        {
                          event_provider = provider;
                          event_model = model;
                          event_body;
                          max_buffer_bytes;
                          max_json_bytes;
                          max_pending_events;
                          line;
                          data;
                          line_length = 0;
                          data_length = 0;
                          framing_bytes = 0;
                          has_data = false;
                          after_cr = false;
                          bom_state = Start;
                          event_pending = [];
                          event_eof = false;
                          event_released = Atomic.make false;
                          event_active = Atomic.make false;
                        }))))
  |> Common.with_provider_span provider ~operation:"speech.stream_events" ~model
       ~attrs:event_attrs
