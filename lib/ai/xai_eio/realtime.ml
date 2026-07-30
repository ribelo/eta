module E = Eta.Effect
module R = Eta_ai_xai.Realtime

type error = Common.error

type t = {
  connection : Common.t;
  input_transport : R.audio_transport Atomic.t;
  output_transport : R.audio_transport Atomic.t;
}

let ( let* ) = Result.bind

let query_values ?model ?reasoning_effort ?call_id ?conversation_id () =
  List.filter_map
    (fun (name, value) -> Option.map (fun value -> (name, value)) value)
    [
      ("model", model);
      ("reasoning.effort", reasoning_effort);
      ("call_id", call_id);
      ("conversation_id", conversation_id);
    ]

let url ?(endpoint = Eta_ai_xai.Endpoint.default_inference) ?model
    ?reasoning_effort ?call_id ?conversation_id () =
  let* base = Common.ws_base_url endpoint in
  Ok
    (Common.query_url base "/v1/realtime"
       (query_values ?model ?reasoning_effort ?call_id ?conversation_id ()))

let input_transport (session : R.session) current =
  match session.input_audio with
  | None -> current
  | Some (audio : R.input_audio) -> audio.transport

let output_transport (session : R.session) current =
  match session.output_audio with
  | None -> current
  | Some (audio : R.output_audio) -> audio.transport

let send_message_locked sender = function
  | Eta_ai.Realtime.Text text -> Common.send_text_locked sender text
  | Eta_ai.Realtime.Binary bytes -> Common.send_binary_locked sender bytes

let send_event t event =
  Common.with_send t.connection @@ fun sender ->
  let next_input, next_output =
    match event with
    | R.Session_update session ->
        ( input_transport session (Atomic.get t.input_transport),
          output_transport session (Atomic.get t.output_transport) )
    | _ -> (Atomic.get t.input_transport, Atomic.get t.output_transport)
  in
  let framing_ok =
    match event with
    | R.Input_audio_buffer_append _ -> next_input = R.Json
    | R.Input_audio_binary _ -> next_input = R.Binary
    | _ -> true
  in
  if not framing_ok then
    E.fail
      (`Invalid_request
        "audio event framing does not match the Realtime session transport")
  else
    send_message_locked sender (R.client_event_message event)
    |> E.map (fun () ->
           Atomic.set t.input_transport next_input;
           Atomic.set t.output_transport next_output)

let send_audio t bytes =
  Common.with_send t.connection @@ fun sender ->
  match Atomic.get t.input_transport with
  | R.Binary -> Common.send_binary_locked sender bytes
  | R.Json ->
      Common.send_text_locked sender
        (match R.client_event_message (R.Input_audio_buffer_append bytes) with
        | Eta_ai.Realtime.Text text -> text
        | Binary _ -> assert false)

let codec_error = function
  | R.Invalid_json message -> message
  | R.Invalid_base64_audio -> "invalid base64 Realtime audio"

let decode_message t message =
  match message with
  | `Text raw ->
      R.decode_server_event (Eta_ai.Realtime.Text raw)
  | `Binary bytes when Atomic.get t.output_transport = R.Binary ->
      R.decode_server_event (Eta_ai.Realtime.Binary bytes)
  | `Binary _ ->
      Error (R.Invalid_json "binary audio received for JSON output transport")

let read_event t =
  Common.read_message t.connection
  |> E.bind (function
       | None -> E.pure None
       | Some message ->
           (match decode_message t message with
           | Ok event ->
               (match event with
               | R.Response_created raw | R.Response_done raw ->
                   Option.iter
                     (fun id ->
                       Common.record_attrs t.connection
                         [ ("gen_ai.response.id", id) ])
                     (Eta_ai.Json.string_member "id" raw)
               | R.Error error ->
                   Option.iter
                     (fun value ->
                       Common.record_attrs t.connection
                         [ ("error.type", value) ])
                     error.code
               | _ -> ());
               E.pure (Some event)
           | Error error ->
               E.fail (`Decode (codec_error error))))

let close t = Common.close t.connection

let attrs (session : R.session) =
  (match session.model with
  | None -> []
  | Some model -> [ ("gen_ai.request.model", model) ])
  @
  let formats =
    List.filter_map Fun.id
      [
        Option.map
          (fun (audio : R.input_audio) ->
            R.audio_format_mime audio.format)
          session.input_audio;
        Option.map
          (fun (audio : R.output_audio) ->
            R.audio_format_mime audio.format)
          session.output_audio;
      ]
  in
  match formats with
  | [] -> []
  | values ->
      [ ("gen_ai.request.encoding_formats", String.concat "," values) ]

let initialize connection session =
  let t =
    {
      connection;
      input_transport = Atomic.make R.Json;
      output_transport = Atomic.make R.Json;
    }
  in
  send_event t (R.Session_update session)
  |> E.map (fun () -> t)
  |> E.on_exit (function
       | Eta.Exit.Ok _ -> E.unit
       | Eta.Exit.Error _ -> close t)

let connect_api_key ?ca_file ?call_id ?conversation_id ~sw ~net ~api_key
    ~(session : R.session) () =
  match
    url ?model:session.model
      ?reasoning_effort:session.reasoning_effort ?call_id ?conversation_id ()
  with
  | Error error -> E.fail (error :> Common.error)
  | Ok raw_url ->
      Common.connect ?ca_file ~attrs:(attrs session) ~operation:"realtime" ~sw ~net
        ~headers:(Common.headers api_key) raw_url
      |> E.bind (fun connection -> initialize connection session)

let connect_ephemeral ?ca_file ?conversation_id ~sw ~net ~secret
    ~(session : R.session) () =
  match
    url ?model:session.model
      ?reasoning_effort:session.reasoning_effort ?conversation_id ()
  with
  | Error error -> E.fail (error :> Common.error)
  | Ok raw_url ->
      let protocol =
        "xai-client-secret."
        ^ Eta_redacted.value (R.client_secret_redacted secret)
      in
      Common.connect ?ca_file ~attrs:(attrs session) ~protocols:[ protocol ]
        ~operation:"realtime" ~sw ~net
        ~headers:Eta_http.Core.Header.empty raw_url
      |> E.bind (fun connection -> initialize connection session)

let connect_api_key_on_flow ?key ~sw ~flow ~api_key url ~session =
  Common.connect_on_flow ?key ~attrs:(attrs session) ~operation:"realtime" ~sw
    ~flow ~headers:(Common.headers api_key) url
  |> E.bind (fun connection -> initialize connection session)

let connect_ephemeral_on_flow ?key ~sw ~flow ~secret url ~session =
  let protocol =
    "xai-client-secret."
    ^ Eta_redacted.value (R.client_secret_redacted secret)
  in
  Common.connect_on_flow ?key ~attrs:(attrs session) ~protocols:[ protocol ]
    ~operation:"realtime" ~sw ~flow ~headers:Eta_http.Core.Header.empty url
  |> E.bind (fun connection -> initialize connection session)

type connection_options =
  | Connection_options : {
      conversation_id : string option;
      net : 'a Eio.Net.t;
      api_key : Eta_ai.api_key;
    } -> connection_options

module Transport = struct
  type nonrec session = R.session
  type nonrec client_event = R.client_event
  type nonrec server_event = R.server_event
  type nonrec error = error
  type scope = Eio.Switch.t
  type nonrec connection_options = connection_options
  type connection = t

  let connect ~scope
      (Connection_options { conversation_id; net; api_key })
      session =
    connect_api_key ?conversation_id ~sw:scope ~net ~api_key ~session ()

  let send = send_event
  let read = read_event
  let close = close
end
