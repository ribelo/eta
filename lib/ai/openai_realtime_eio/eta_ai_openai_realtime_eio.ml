module E = Eta.Effect
module A = Eta_ai
module Openai = Eta_ai_openai
module Ws = Eta_http_eio.Ws.Client
module Json = A.Json

type connection_options =
  | Connection_options : {
      base_url : string option;
      safety_identifier : string option;
      max_message_size : int option;
      max_pending_events : int option;
      net : 'a Eio.Net.t;
      api_key : A.api_key;
    } -> connection_options

type engine_error =
  | Websocket of Ws.ws_error
  | Openai_error of Openai.Error.t
  | Concurrent_read
  | Already_finished
  | Finished
  | Aborted
  | Timeout

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode value =
  let out = Buffer.create (String.length value) in
  String.iter
    (fun char ->
      if is_unreserved char then Buffer.add_char out char
      else Buffer.add_string out (Printf.sprintf "%%%02X" (Char.code char)))
    value;
  Buffer.contents out

let rewrite_prefix value ~prefix ~replacement =
  replacement ^ String.sub value (String.length prefix)
    (String.length value - String.length prefix)

let ws_base_url ?(base_url = "wss://api.openai.com") () =
  let base_url = A.trim_trailing_slash base_url in
  if Eta.String_helpers.starts_with base_url ~prefix:"https://" then
    rewrite_prefix base_url ~prefix:"https://" ~replacement:"wss://"
  else if Eta.String_helpers.starts_with base_url ~prefix:"http://" then
    rewrite_prefix base_url ~prefix:"http://" ~replacement:"ws://"
  else base_url

let default_max_message_size = Ws.default_max_frame_size
let default_max_pending_events = Ws.default_incoming_capacity

let websocket_headers ?safety_identifier api_key =
  Eta_http.Core.Header.unsafe_of_list
    (("Authorization", "Bearer " ^ Eta_redacted.value api_key)
     :: match safety_identifier with
        | None -> []
        | Some value -> [ ("OpenAI-Safety-Identifier", value) ])

let decode_failure ?raw_body message =
  Openai.Error.Decode { message; raw_body }

let validate_bounds max_message_size max_pending_events =
  match max_message_size, max_pending_events with
  | Some value, _ when value < 0 ->
      Error (Openai.Error.Invalid_request
        "Realtime max_message_size must be non-negative")
  | _, Some value when value <= 0 ->
      Error (Openai.Error.Invalid_request
        "Realtime max_pending_events must be positive")
  | _ -> Ok ()

module type Protocol = sig
  type session
  type client_event
  type server_event
  type codec_error
  module Codec : A.Realtime.Codec
    with type session = session
     and type client_event = client_event
     and type server_event = server_event
     and type error = codec_error
  val protocol : string
  val path : string
  val model : session -> (string, Openai.Error.t) result
  val validate_session : session -> (unit, Openai.Error.t) result
  val validate_event : client_event -> (unit, Openai.Error.t) result
  val finish_plan : unit -> client_event list * (server_event -> bool)
  val codec_error : codec_error -> Openai.Error.t
end

module Engine = struct
  type telemetry_end = { lifecycle : string; error_type : string option }

  type ('session, 'client_event, 'server_event, 'codec_error) t = {
    ws : Ws.t;
    send_mutex : Eio.Mutex.t;
    read_active : bool Atomic.t;
    state : int Atomic.t;
    released : bool Atomic.t;
    terminal : (unit, engine_error) result Eio.Promise.t;
    terminal_resolver : (unit, engine_error) result Eio.Promise.u;
    terminal_resolved : bool Atomic.t;
    telemetry_resolver : telemetry_end Eio.Promise.u;
    telemetry_resolved : bool Atomic.t;
    mutable is_terminal : 'server_event -> bool;
  }

  let resolve_once flag resolver value =
    if Atomic.compare_and_set flag false true then Eio.Promise.resolve resolver value

  let websocket_error_type = function
    | `Connect _ -> "connect_error"
    | `Upgrade_failed _ -> "upgrade_error"
    | `Closed (code, _) -> "websocket_closed_" ^ string_of_int code
    | `Protocol _ -> "protocol_error"
    | `Timeout -> "timeout"

  let error_type = function
    | Websocket error -> websocket_error_type error
    | Openai_error error -> Openai.Error.classification error
    | Concurrent_read -> "concurrent_read"
    | Already_finished -> "already_finished"
    | Finished -> "finished"
    | Aborted -> "aborted"
    | Timeout -> "timeout"

  let close_once ?terminal ?error_type ?(lifecycle = "abort") t =
    E.sync (fun () ->
        Option.iter
          (resolve_once t.terminal_resolved t.terminal_resolver)
          terminal;
        resolve_once t.telemetry_resolved t.telemetry_resolver
          { lifecycle; error_type };
        Atomic.compare_and_set t.released false true)
    |> E.bind (fun release ->
           if release then E.map_error (fun error -> Websocket error) (Ws.close t.ws)
           else E.unit)

  let mark_aborted t =
    let rec loop () =
      match Atomic.get t.state with
      | 2 | 3 -> false
      | state ->
          if Atomic.compare_and_set t.state state 2 then true else loop ()
    in
    loop ()

  let abort_with ?terminal_error ?error_type ?(lifecycle = "abort") t =
    E.sync (fun () -> mark_aborted t)
    |> E.bind (fun _ ->
           let terminal =
             Option.map (fun error -> Error error) terminal_error
             |> Option.value ~default:(Error Aborted)
           in
           close_once ~terminal ?error_type ~lifecycle t)

  let fail_with_cleanup t error =
    E.fail error
    |> E.finally
         (abort_with ~terminal_error:error ~error_type:(error_type error)
            ~lifecycle:"failure" t)

  let abort t = abort_with t

  let terminal t =
    E.sync (fun () -> Atomic.set t.state 3)
    |> E.bind (fun () -> close_once ~terminal:(Ok ()) ~lifecycle:"finish" t)

  let authority_of_url raw_url =
    match Eta_http.Core.Url.parse raw_url with
    | Error _ -> []
    | Ok url ->
        ("server.address", Eta_http.Core.Url.host url)
        :: (match Eta_http.Core.Url.port url with
            | None -> []
            | Some port -> [ ("server.port", string_of_int port) ])

  let span_attrs ~protocol ~raw_url ?error_type () =
    [ ("gen_ai.provider.name", "openai");
      ("gen_ai.operation.name", "realtime");
      ("eta.realtime.protocol", protocol);
      ("eta.stream", "true") ]
    @ Option.fold ~none:[]
        ~some:(fun value -> [ ("error.type", value) ])
        error_type
    @ authority_of_url raw_url

  (* Connect and upgrade failures happen before the connection's telemetry
     daemon exists, so they emit their span directly. *)
  let fail_with_span ~protocol ~raw_url error =
    E.fail error
    |> E.on_error (fun cause ->
           let error_type =
             match cause with
             | Eta.Cause.Fail (Websocket ws_error) ->
                 websocket_error_type ws_error
             | Eta.Cause.Fail error -> error_type error
             | _ -> "connect_error"
           in
           E.unit
           |> Eta_observability.annotate_all
                (span_attrs ~protocol ~raw_url ~error_type ()
                 @ [ ("eta.realtime.lifecycle", "connect_failure") ])
           |> Eta_observability.named ~kind:Eta.Capabilities.Client
                ("realtime openai " ^ protocol))

  let make ~sw ~protocol ~raw_url ws =
    let terminal, terminal_resolver = Eio.Promise.create () in
    let telemetry, telemetry_resolver = Eio.Promise.create () in
    let t =
      { ws; send_mutex = Eio.Mutex.create (); read_active = Atomic.make false;
        state = Atomic.make 0; released = Atomic.make false;
        terminal; terminal_resolver; terminal_resolved = Atomic.make false;
        telemetry_resolver; telemetry_resolved = Atomic.make false;
        is_terminal = (fun _ -> false) }
    in
    Eio.Switch.on_release sw (fun () ->
        resolve_once t.telemetry_resolved t.telemetry_resolver
          { lifecycle = "scope_release"; error_type = None });
    let authority = authority_of_url raw_url in
    Eta.Spi.daemon
      (E.sync (fun () -> Eio.Promise.await telemetry)
       |> E.bind (fun ending ->
              E.unit |> Eta_observability.annotate_all
                ([ ("gen_ai.provider.name", "openai");
                   ("gen_ai.operation.name", "realtime");
                   ("eta.realtime.protocol", protocol);
                   ("eta.realtime.lifecycle", ending.lifecycle);
                   ("eta.stream", "true") ]
                 @ Option.fold ~none:[]
                     ~some:(fun value -> [ ("error.type", value) ])
                     ending.error_type
                 @ authority))
       |> Eta_observability.named ~kind:Eta.Capabilities.Client
            ("realtime openai " ^ protocol))
    |> E.map (fun () -> t)

  let connect ?base_url ?safety_identifier ?max_message_size
      ?max_pending_events ~sw ~net ~api_key ~protocol ~path ~model () =
    let raw_url =
      ws_base_url ?base_url () ^ path ^ "?model=" ^ percent_encode model
    in
    Ws.connect ?max_frame_size:max_message_size
      ?incoming_capacity:max_pending_events
      ~headers:(websocket_headers ?safety_identifier api_key) ~sw ~net raw_url
    |> A.suppress_provider_transport_observability
    |> E.map_error (fun error -> Websocket error)
    |> E.bind_error (fail_with_span ~protocol ~raw_url)
    |> E.bind (make ~sw ~protocol ~raw_url)

  let connect_on_flow ?key ?safety_identifier ?max_message_size
      ?max_pending_events ~sw ~flow ~api_key ~protocol url =
    Ws.connect_on_flow ?key ?max_frame_size:max_message_size
      ?incoming_capacity:max_pending_events
      ~headers:(websocket_headers ?safety_identifier api_key) ~sw ~flow url
    |> A.suppress_provider_transport_observability
    |> E.map_error (fun error -> Websocket error)
    |> E.bind_error
         (fail_with_span ~protocol
            ~raw_url:(Eta_http.Core.Url.to_string url))
    |> E.bind (make ~sw ~protocol
         ~raw_url:(Eta_http.Core.Url.to_string url))

  let with_send_lock t f =
    E.sync (fun () -> Eio.Mutex.lock t.send_mutex)
    |> E.bind (fun () ->
           f ()
           |> E.on_exit (fun _ ->
                  E.sync (fun () -> Eio.Mutex.unlock t.send_mutex)))

  let send_message_locked t = function
    | A.Realtime.Text text ->
        Ws.send_text t.ws text |> E.map_error (fun error -> Websocket error)
    | A.Realtime.Binary bytes ->
        Ws.send_binary t.ws bytes |> E.map_error (fun error -> Websocket error)

  let send t encode event =
    with_send_lock t @@ fun () ->
    match Atomic.get t.state with
    | 0 ->
        send_message_locked t (encode event)
        |> E.bind_error (fail_with_cleanup t)
    | 1 | 3 -> E.fail Finished
    | 2 -> E.fail Aborted
    | _ -> assert false

  let read_message t =
    Ws.incoming t.ws |> Eta_stream.Stream.take 1 |> Eta_stream.run_collect
    |> E.map_error (fun error -> Websocket error)

  let read t decode codec_error =
    E.sync (fun () -> Atomic.compare_and_set t.read_active false true)
    |> E.bind (fun acquired ->
      if not acquired then E.fail Concurrent_read
      else
        (read_message t
         |> E.bind_error (fail_with_cleanup t)
         |> E.bind (function
              | [] -> abort t |> E.map (fun () -> None)
              | [ message ] ->
                  let frame =
                    match message with
                    | `Text raw -> A.Realtime.Text raw
                    | `Binary bytes -> A.Realtime.Binary bytes
                  in
                  (match decode frame with
                   | Error codec ->
                       fail_with_cleanup t (Openai_error (codec_error codec))
                   | Ok event ->
                       (* A typed provider error event is delivered in-band:
                          the caller decides whether to continue or abort. *)
                       (match Atomic.get t.state = 1 && t.is_terminal event with
                        | true -> terminal t |> E.map (fun () -> Some event)
                        | false -> E.pure (Some event)))
              | _ -> assert false)
         |> E.on_exit (fun exit ->
                let reset =
                  E.sync (fun () -> Atomic.set t.read_active false)
                in
                match exit with
                | Eta.Exit.Error cause
                  when Eta.Cause.is_interrupt_only cause ->
                    reset |> E.finally (abort t)
                | Eta.Exit.Ok _ | Eta.Exit.Error _ -> reset)))

  let finish t encode plan =
    let start =
      with_send_lock t @@ fun () ->
      match Atomic.get t.state with
      | 0 ->
          Atomic.set t.state 1;
          let events, is_terminal = plan () in
          t.is_terminal <- is_terminal;
          let rec send_all = function
            | [] -> E.unit
            | event :: rest ->
                send_message_locked t (encode event)
                |> E.bind (fun () -> send_all rest)
          in
          send_all events |> E.bind_error (fail_with_cleanup t)
      | 1 | 3 -> E.fail Already_finished
      | 2 -> E.fail Aborted
      | _ -> assert false
    in
    start
    |> E.bind (fun () -> E.sync (fun () -> Eio.Promise.await t.terminal))
    |> E.bind (function Ok () -> E.unit | Error error -> E.fail error)
end

module Make (P : Protocol) = struct
  type t = (P.session, P.client_event, P.server_event, P.codec_error) Engine.t
  type error =
    | Websocket of Ws.ws_error
    | Openai_error of Openai.Error.t
    | Concurrent_read
    | Already_finished
    | Finished
    | Aborted
    | Timeout

  let error_of_engine (value : engine_error) : error =
    match value with
    | Websocket error -> Websocket error
    | Openai_error error -> Openai_error error
    | Concurrent_read -> Concurrent_read
    | Already_finished -> Already_finished
    | Finished -> Finished
    | Aborted -> Aborted
    | Timeout -> Timeout

  let public (eff : ('a, engine_error) E.t) : ('a, error) E.t =
    E.map_error error_of_engine eff

  let send_session t session =
    Engine.with_send_lock t (fun () ->
        Engine.send_message_locked t (P.Codec.encode_session session))

  let connect ?base_url ?safety_identifier ?max_message_size
      ?max_pending_events ~sw ~net ~api_key ~session () =
    let validated =
      Result.bind (validate_bounds max_message_size max_pending_events)
        (fun () ->
          Result.bind (P.validate_session session) (fun () -> P.model session))
    in
    match validated with
    | Error error -> E.fail (Openai_error error)
    | Ok model ->
        Engine.connect ?base_url ?safety_identifier ?max_message_size
          ?max_pending_events ~sw ~net ~api_key ~protocol:P.protocol
          ~path:P.path ~model ()
        |> E.bind (fun t ->
               send_session t session
               |> E.bind_error (Engine.fail_with_cleanup t)
               |> E.map (fun () -> t)
               |> E.on_exit (function
                    | Eta.Exit.Error cause
                      when Eta.Cause.is_interrupt_only cause ->
                        Engine.abort t
                    | Eta.Exit.Ok _ | Eta.Exit.Error _ -> E.unit))
        |> public

  let connect_session_on_flow ?key ?safety_identifier ?max_message_size
      ?max_pending_events ~sw ~flow ~api_key url session =
    let validated =
      Result.bind (validate_bounds max_message_size max_pending_events)
        (fun () -> P.validate_session session)
    in
    match validated with
    | Error error -> E.fail (Openai_error error)
    | Ok () ->
        Engine.connect_on_flow ?key ?safety_identifier ?max_message_size
          ?max_pending_events ~sw ~flow ~api_key ~protocol:P.protocol url
        |> E.bind (fun t ->
               send_session t session
               |> E.bind_error (Engine.fail_with_cleanup t)
               |> E.map (fun () -> t)
               |> E.on_exit (function
                    | Eta.Exit.Error cause
                      when Eta.Cause.is_interrupt_only cause ->
                        Engine.abort t
                    | Eta.Exit.Ok _ | Eta.Exit.Error _ -> E.unit))
        |> public

  let send_event t event =
    (match P.validate_event event with
     | Ok () -> Engine.send t P.Codec.encode_client_event event
     | Error error -> E.fail ((Openai_error error : engine_error)))
    |> public

  let read_event t =
    Engine.read t P.Codec.decode_server_event P.codec_error
    |> public

  let rec events t =
    Eta_stream.Stream.from_effect (read_event t)
    |> Eta_stream.Stream.flat_map (function
         | None -> Eta_stream.Stream.empty
         | Some event ->
             Eta_stream.Stream.concat (Eta_stream.Stream.succeed event) (events t))

  let finish t =
    Engine.finish t P.Codec.encode_client_event P.finish_plan
    |> E.on_interrupt (fun _ -> Engine.abort t)
    |> public

  let finish_with_timeout ~timeout t =
    (* [timeout_as] preserves the finish exit exactly, cancels the timer when
       finish wins, waits for finish cleanup when the timer wins, and cancels
       both on parent interruption. The [on_exit] observer aborts only on exits
       whose cause tree contains the typed [Timeout] failure — which [finish]
       itself never produces — and otherwise performs the ordinary one-shot
       abort only for parent interruption. Abort cleanup failure is reported as
       a finalizer diagnostic suppressed beneath the winning cause by
       [on_exit]. *)
    let finish =
      Engine.finish t P.Codec.encode_client_event P.finish_plan |> public
    in
    Eta.Effect.timeout_as timeout ~on_timeout:Timeout finish
    |> E.on_exit (function
         | Eta.Exit.Ok () -> E.unit
         | Eta.Exit.Error cause ->
             if
               List.exists
                 (function Timeout -> true | _ -> false)
                 (Eta.Cause.failures cause)
             then
               Engine.abort_with ~terminal_error:Timeout ~lifecycle:"timeout"
                 ~error_type:"timeout" t
               |> public
             else if Eta.Cause.is_interrupt_only cause then
               Engine.abort t |> public
             else E.unit)

  let abort t = Engine.abort t |> public
end

module Conversation_protocol = struct
  module R = Openai.Audio.Realtime.Conversation
  type session = R.session
  type client_event = R.client_event
  type server_event = R.server_event
  type codec_error = R.codec_error
  module Codec = R.Codec
  let protocol = "conversation"
  let path = "/v1/realtime"
  let model session = match session.R.model with Some model -> Ok model | None -> Error (Openai.Error.Invalid_request "Realtime Conversation session requires a model")
  let validate_session _ = Ok ()
  let validate_event event =
    let event_id =
      match event with
      | R.Session_update { event_id; _ }
      | R.Input_audio_buffer_append { event_id; _ }
      | R.Input_audio_buffer_commit { event_id }
      | R.Input_audio_buffer_clear { event_id }
      | R.Conversation_item_create { event_id; _ }
      | R.Conversation_item_retrieve { event_id; _ }
      | R.Conversation_item_truncate { event_id; _ }
      | R.Conversation_item_delete { event_id; _ }
      | R.Response_create { event_id; _ }
      | R.Response_cancel { event_id; _ }
      | R.Output_audio_buffer_clear { event_id } -> event_id
    in
    match event_id with
    | Some value when String.length value > 512 ->
        Error
          (Openai.Error.Invalid_request
             "Realtime Conversation event_id must not exceed 512 bytes")
    | _ -> (
        match event with
        | R.Conversation_item_truncate { content_index; audio_end_ms; _ }
          when content_index < 0 || audio_end_ms < 0 ->
            Error
              (Openai.Error.Invalid_request
                 "Realtime Conversation truncate indices must be non-negative")
        | _ -> Ok ())
  let finish_counter = Atomic.make 0
  let response_id json =
    Option.bind (A.Json.object_member "response" json)
      (A.Json.string_member "id")
  let response_finish_tag json =
    Option.bind (A.Json.object_member "response" json) (fun response ->
    Option.bind (A.Json.object_member "metadata" response)
      (A.Json.string_member "eta_finish_id"))
  let finish_plan () =
    let tag =
      "eta_finish_" ^ string_of_int (Atomic.fetch_and_add finish_counter 1)
    in
    let response =
      Json.object_
        [ ("metadata",
            Some (Json.object_
              [ ("eta_finish_id", Some (Json.string tag)) ])) ]
    in
    let target = ref None in
    ( [ R.Input_audio_buffer_commit { event_id = None };
        R.Response_create { response = Some response; event_id = None } ],
      function
      | R.Response_created raw
        when response_finish_tag raw = Some tag ->
          target := response_id raw;
          false
      | R.Response_done raw ->
          (match !target, response_id raw with
           | Some expected, Some actual -> String.equal expected actual
           | _ -> false)
      | _ -> false )
  let codec_error (R.Decode { message; raw_body }) = decode_failure ?raw_body message
end
module Conversation_engine = Make (Conversation_protocol)

module Transcription_protocol = struct
  module R = Openai.Audio.Realtime.Transcription
  type session = R.session
  type client_event = R.client_event
  type server_event = R.server_event
  type codec_error = R.codec_error
  module Codec = R.Codec
  let protocol = "transcription"
  let path = "/v1/realtime"
  let model session = Ok session.R.transcription.model
  let valid_keyword value =
    not (String.exists (fun char ->
        char = '<' || char = '>' || char = '\r' || char = '\n') value)
  let validate_session session =
    if List.for_all valid_keyword session.R.transcription.keywords then Ok ()
    else Error (Openai.Error.Invalid_request
      "Realtime Transcription keywords must be one line and contain no '<' or '>'")
  let event_id = function
    | R.Session_update { event_id; _ }
    | R.Input_audio_buffer_append { event_id; _ }
    | R.Input_audio_buffer_commit { event_id }
    | R.Input_audio_buffer_clear { event_id } -> event_id
  let validate_event event =
    match event_id event with
    | Some value when String.length value > 512 ->
        Error (Openai.Error.Invalid_request
          "Realtime Transcription event_id must not exceed 512 bytes")
    | _ -> Ok ()
  let finish_plan () =
    let target = ref None in
    ( [ R.Input_audio_buffer_commit { event_id = None } ],
      function
      | R.Input_audio_buffer_committed raw ->
          target := A.Json.string_member "item_id" raw;
          false
      | R.Transcription_completed { item_id; _ } ->
          (match !target with
           | Some expected -> String.equal expected item_id
           | None -> false)
      | R.Transcription_failed { item_id; _ } ->
          (match !target with
           | Some expected -> String.equal expected item_id
           | None -> false)
      | _ -> false )
  let codec_error (R.Decode { message; raw_body }) = decode_failure ?raw_body message
end
module Transcription_engine = Make (Transcription_protocol)

module Translation_protocol = struct
  module R = Openai.Audio.Realtime.Translation
  type session = R.session
  type client_event = R.client_event
  type server_event = R.server_event
  type codec_error = R.codec_error
  module Codec = R.Codec
  let protocol = "translation"
  let path = "/v1/realtime/translations"
  let model session = Ok session.R.model
  let event_id = function
    | R.Session_update { event_id; _ }
    | R.Input_audio_buffer_append { event_id; _ }
    | R.Session_close { event_id } -> event_id
  let validate_session _ = Ok ()
  let validate_event event =
    match event_id event with
    | Some value when String.length value > 512 ->
        Error (Openai.Error.Invalid_request
          "Realtime Translation event_id must not exceed 512 bytes")
    | _ ->
        (match event with
         | R.Input_audio_buffer_append { audio = { A.format = A.Pcm16; _ }; _ }
         | R.Session_update _ | R.Session_close _ -> Ok ()
         | R.Input_audio_buffer_append _ ->
             Error (Openai.Error.Invalid_request
               "Realtime Translation WebSocket audio must be PCM16"))
  let finish_plan () =
    ([ R.Session_close { event_id = None } ],
     function R.Session_closed _ -> true | _ -> false)
  let codec_error (R.Decode { message; raw_body }) = decode_failure ?raw_body message
end
module Translation_engine = Make (Translation_protocol)

module Conversation = struct
  module R = Openai.Audio.Realtime.Conversation
  include Conversation_engine
  module Transport = struct
    type nonrec session = R.session
    type nonrec client_event = R.client_event
    type nonrec server_event = R.server_event
    type nonrec error = error
    type scope = Eio.Switch.t
    type nonrec connection_options = connection_options
    type connection = t
    let connect ~scope (Connection_options { base_url; safety_identifier; max_message_size; max_pending_events; net; api_key }) session =
      connect ?base_url ?safety_identifier ?max_message_size ?max_pending_events ~sw:scope ~net ~api_key ~session ()
    let send = send_event
    let read = read_event
    let close = abort
  end
end

module Transcription = struct
  module R = Openai.Audio.Realtime.Transcription
  include Transcription_engine
  module Transport = struct
    type nonrec session = R.session
    type nonrec client_event = R.client_event
    type nonrec server_event = R.server_event
    type nonrec error = error
    type scope = Eio.Switch.t
    type nonrec connection_options = connection_options
    type connection = t
    let connect ~scope (Connection_options { base_url; safety_identifier; max_message_size; max_pending_events; net; api_key }) session =
      connect ?base_url ?safety_identifier ?max_message_size ?max_pending_events ~sw:scope ~net ~api_key ~session ()
    let send = send_event
    let read = read_event
    let close = abort
  end
end

module Translation = struct
  module R = Openai.Audio.Realtime.Translation
  include Translation_engine
  module Transport = struct
    type nonrec session = R.session
    type nonrec client_event = R.client_event
    type nonrec server_event = R.server_event
    type nonrec error = error
    type scope = Eio.Switch.t
    type nonrec connection_options = connection_options
    type connection = t
    let connect ~scope (Connection_options { base_url; safety_identifier; max_message_size; max_pending_events; net; api_key }) session =
      connect ?base_url ?safety_identifier ?max_message_size ?max_pending_events ~sw:scope ~net ~api_key ~session ()
    let send = send_event
    let read = read_event
    let close = abort
  end
end
