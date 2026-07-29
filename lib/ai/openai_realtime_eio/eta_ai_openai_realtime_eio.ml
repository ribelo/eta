module E = Eta.Effect
module Realtime = Eta_ai_openai.Realtime

type realtime_error = Eta_http_eio.Ws.Client.ws_error
type t = { ws : Eta_http_eio.Ws.Client.t } [@@unboxed]

type connection_options =
  | Connection_options : {
      base_url : string option;
      safety_identifier : string option;
      net : 'a Eio.Net.t;
      api_key : Eta_ai.api_key;
    } -> connection_options

let trim_trailing_slash = Eta_ai.trim_trailing_slash

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode value =
  let out = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char out c
      else (
        let code = Char.code c in
        Buffer.add_char out '%';
        Buffer.add_char out (Eta.String_helpers.upper_hex_digit (code lsr 4));
        Buffer.add_char out (Eta.String_helpers.upper_hex_digit (code land 0xf))))
    value;
  Buffer.contents out

let rewrite_prefix value ~prefix ~replacement =
  let prefix_len = String.length prefix in
  let replacement_len = String.length replacement in
  let suffix_len = String.length value - prefix_len in
  let bytes = Bytes.create (replacement_len + suffix_len) in
  Bytes.blit_string replacement 0 bytes 0 replacement_len;
  Bytes.blit_string value prefix_len bytes replacement_len suffix_len;
  Bytes.unsafe_to_string bytes

let ws_base_url ?(base_url = "wss://api.openai.com") () =
  let base_url = trim_trailing_slash base_url in
  if Eta.String_helpers.starts_with base_url ~prefix:"https://" then
    rewrite_prefix base_url ~prefix:"https://" ~replacement:"wss://"
  else if Eta.String_helpers.starts_with base_url ~prefix:"http://" then
    rewrite_prefix base_url ~prefix:"http://" ~replacement:"ws://"
  else base_url

let realtime_url ?base_url ~model () =
  ws_base_url ?base_url () ^ "/v1/realtime?model=" ^ percent_encode model

let websocket_headers ?safety_identifier api_key =
  Eta_http.Core.Header.unsafe_of_list
    (("Authorization", "Bearer " ^ Eta_redacted.value api_key)
    :: match safety_identifier with
       | None -> []
       | Some value -> [ ("OpenAI-Safety-Identifier", value) ])

let connect ?base_url ?safety_identifier ~sw ~net ~api_key ~model () =
  Eta_http_eio.Ws.Client.connect
    ~headers:(websocket_headers ?safety_identifier api_key)
    ~sw ~net
    (realtime_url ?base_url ~model ())
  |> E.map (fun ws -> { ws })

let connect_on_flow ?key ?safety_identifier ~sw ~flow ~api_key url =
  Eta_http_eio.Ws.Client.connect_on_flow ?key
    ~headers:(websocket_headers ?safety_identifier api_key)
    ~sw ~flow url
  |> E.map (fun ws -> { ws })

let send_message t = function
  | Eta_ai.Realtime.Text text -> Eta_http_eio.Ws.Client.send_text t.ws text
  | Eta_ai.Realtime.Binary bytes ->
      Eta_http_eio.Ws.Client.send_binary t.ws bytes

let send_event t event =
  send_message t (Realtime.Codec.encode_client_event event)

let decode_message = function
  | `Text raw ->
      Realtime.Codec.decode_server_event (Eta_ai.Realtime.Text raw)
  | `Binary bytes ->
      Realtime.Codec.decode_server_event (Eta_ai.Realtime.Binary bytes)

let events t =
  Eta_http_eio.Ws.Client.incoming t.ws
  |> Eta_stream.Stream.map (fun message ->
         match decode_message message with
         | Stdlib.Ok event -> event
         | Stdlib.Error error ->
             Realtime.Server_decode_error
               {
                 message = Realtime.codec_error_message error;
                 raw = None;
               })

let close t = Eta_http_eio.Ws.Client.close t.ws

let read_event t =
  Eta_http_eio.Ws.Client.incoming t.ws
  |> Eta_stream.Stream.take 1
  |> Eta_stream.run_collect
  |> E.bind (function
       | [] -> E.pure None
       | [ message ] -> (
           match decode_message message with
           | Stdlib.Ok event -> E.pure (Some event)
           | Stdlib.Error error ->
               E.fail (`Protocol (Realtime.codec_error_message error)))
       | _ -> assert false)

let initialize t session =
  (send_event t (Realtime.Session_update session) |> E.map (fun () -> t))
  |> E.on_exit (function
       | Eta.Exit.Ok _ -> E.unit
       | Eta.Exit.Error _ -> close t)

let connect_session_on_flow ?key ?safety_identifier ~sw ~flow ~api_key url
    session =
  connect_on_flow ?key ?safety_identifier ~sw ~flow ~api_key url
  |> E.bind (fun connection -> initialize connection session)

module Transport = struct
  type nonrec session = Realtime.session
  type nonrec client_event = Realtime.client_event
  type nonrec server_event = Realtime.server_event
  type nonrec error = realtime_error
  type scope = Eio.Switch.t
  type nonrec connection_options = connection_options
  type connection = t

  let connect ~scope
      (Connection_options { base_url; safety_identifier; net; api_key })
      (session : session) =
    match session.model with
    | None ->
        E.fail
          (`Protocol "OpenAI Realtime session requires a model for connection")
    | Some model ->
        connect ?base_url ?safety_identifier ~sw:scope ~net ~api_key ~model ()
        |> E.bind (fun connection -> initialize connection session)

  let send = send_event
  let read = read_event
  let close = close
end
