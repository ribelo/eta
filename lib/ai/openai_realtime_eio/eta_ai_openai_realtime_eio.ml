module E = Eta.Effect
module Realtime = Eta_ai_openai.Realtime

type realtime_error = Eta_http_eio.Ws.Client.ws_error
type t = { ws : Eta_http_eio.Ws.Client.t } [@@unboxed]

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

let send_event t event =
  Eta_http_eio.Ws.Client.send_text t.ws (Realtime.client_event_to_string event)

let events t =
  Eta_http_eio.Ws.Client.incoming t.ws
  |> Eta_stream.Stream.map (function
       | `Text raw -> Realtime.decode_server_event raw
       | `Binary _ ->
           Realtime.Server_decode_error
             { message = "OpenAI Realtime sent binary WebSocket message"; raw = None })

let close t = Eta_http_eio.Ws.Client.close t.ws
