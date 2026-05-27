module A = Eta_ai
module E = Eta.Effect
module Json = A.Json

type modality = Text | Audio

type session = {
  model : string option;
  instructions : string option;
  output_modalities : modality list;
  input_audio_format : A.audio_format option;
  output_audio_format : A.audio_format option;
  voice : string option;
  turn_detection : A.Json.t option;
  tools : A.Json.t option;
  tool_choice : string option;
  max_output_tokens : int option;
}

let session ?model ?instructions ?(output_modalities = [ Text; Audio ])
    ?input_audio_format ?output_audio_format ?voice ?turn_detection ?tools
    ?tool_choice ?max_output_tokens () =
  {
    model;
    instructions;
    output_modalities;
    input_audio_format;
    output_audio_format;
    voice;
    turn_detection;
    tools;
    tool_choice;
    max_output_tokens;
  }

let modality_json = function Text -> Json.string "text" | Audio -> Json.string "audio"

let audio_format_json = function
  | A.Pcm16 ->
      Json.object_
        [ ("type", Some (Json.string "audio/pcm")); ("rate", Some (Json.int 24000)) ]
  | A.G711_alaw -> Json.object_ [ ("type", Some (Json.string "audio/pcma")) ]
  | A.G711_ulaw -> Json.object_ [ ("type", Some (Json.string "audio/pcmu")) ]
  | A.Mp3 -> Json.object_ [ ("type", Some (Json.string "audio/mpeg")) ]
  | A.Opus -> Json.object_ [ ("type", Some (Json.string "audio/opus")) ]
  | A.Wav -> Json.object_ [ ("type", Some (Json.string "audio/wav")) ]

let input_audio_json format turn_detection =
  Json.object_
    [
      ("format", Option.map audio_format_json format);
      ("turn_detection", turn_detection);
    ]

let output_audio_json format voice =
  Json.object_
    [ ("format", Option.map audio_format_json format); ("voice", Option.map Json.string voice) ]

let session_json session =
  Json.object_
    [
      ("type", Some (Json.string "realtime"));
      ("model", Option.map Json.string session.model);
      ("instructions", Option.map Json.string session.instructions);
      ( "output_modalities",
        Some (Json.array (List.map modality_json session.output_modalities)) );
      ( "audio",
        Some
          (Json.object_
             [
               ( "input",
                 Some
                   (input_audio_json session.input_audio_format
                      session.turn_detection) );
               ( "output",
                 Some (output_audio_json session.output_audio_format session.voice) );
             ]) );
      ("tools", session.tools);
      ("tool_choice", Option.map Json.string session.tool_choice);
      ("max_output_tokens", Option.map Json.int session.max_output_tokens);
    ]

let session_to_string session = session_json session |> Json.to_string

type client_secret = {
  value : string;
  expires_at : int option;
  raw : A.raw_json option;
}

let trim_trailing_slash value =
  if String.ends_with ~suffix:"/" value then
    String.sub value 0 (String.length value - 1)
  else value

let http_base_url ?(base_url = "https://api.openai.com") () =
  trim_trailing_slash base_url

let auth_headers api_key =
  Eta_http.Core.Header.unsafe_of_list
    [
      ("Authorization", "Bearer " ^ Eta_redacted.value api_key);
      ("Content-Type", "application/json");
      ("Accept", "application/json");
    ]

let client_secret_request ?base_url ~api_key session =
  let body =
    Json.object_ [ ("session", Some (session_json session)) ] |> Json.to_string
  in
  Eta_http.Request.make ~headers:(auth_headers api_key)
    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
    "POST"
    (http_base_url ?base_url () ^ "/v1/realtime/client_secrets")

let read_response_body body =
  Eta_http.Body.Stream.read_all body
  |> E.catch (fun error -> E.fail (A.Eta_http_error error))
  |> E.map Bytes.to_string

let decode_client_secret raw =
  match Json.parse raw with
  | Stdlib.Error message ->
      Stdlib.Error (A.Decode_error { provider = "openai"; message; raw = Some raw })
  | Stdlib.Ok json -> (
      match Json.string_member "value" json with
      | Some value ->
          Stdlib.Ok { value; expires_at = Json.int_member "expires_at" json; raw = Some raw }
      | None ->
          Stdlib.Error
            (A.Decode_error
               {
                 provider = "openai";
                 message = "Realtime client secret response missing value";
                 raw = Some raw;
               }))

let create_client_secret ?base_url client ~api_key session =
  let request = client_secret_request ?base_url ~api_key session in
  Eta_http.request client request
  |> E.suppress_observability
  |> E.catch (fun error -> E.fail (A.Eta_http_error error))
  |> E.bind (fun (response : Eta_http.Response.t) ->
         read_response_body response.Eta_http.Response.body
         |> E.bind (fun raw ->
                if response.status >= 200 && response.status < 300 then
                  match decode_client_secret raw with
                  | Stdlib.Ok secret -> E.pure secret
                  | Stdlib.Error error -> E.fail error
                else
                  E.fail
                    (Common.decode_error ~status:response.status
                       ~headers:response.headers raw)))

type client_event =
  | Session_update of session
  | Input_audio_buffer_append of A.audio
  | Input_audio_buffer_commit
  | Response_create
  | Raw_client_event of A.Json.t

type server_error = {
  code : string option;
  message : string;
  raw : A.raw_json option;
}

type server_event =
  | Session_created of A.raw_json option
  | Response_audio_delta of string
  | Response_text_delta of string
  | Response_done of A.raw_json option
  | Input_audio_buffer_committed
  | Server_error of server_error
  | Server_decode_error of { message : string; raw : A.raw_json option }
  | Raw_server_event of { type_ : string option; raw : A.raw_json }

type realtime_error = [ Eta_http.Ws.Client.ws_error | `Encode of string ]

let widen_ws_error (error : Eta_http.Ws.Client.ws_error) : realtime_error =
  (error :> realtime_error)

let base64_table =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

let base64_encode input =
  let len = String.length input in
  let out = Buffer.create (((len + 2) / 3) * 4) in
  let byte index = if index < len then Char.code input.[index] else 0 in
  let rec loop index =
    if index < len then (
      let b0 = byte index in
      let b1 = byte (index + 1) in
      let b2 = byte (index + 2) in
      Buffer.add_char out base64_table.[b0 lsr 2];
      Buffer.add_char out base64_table.[((b0 land 0x03) lsl 4) lor (b1 lsr 4)];
      if index + 1 < len then
        Buffer.add_char out base64_table.[((b1 land 0x0f) lsl 2) lor (b2 lsr 6)]
      else Buffer.add_char out '=';
      if index + 2 < len then Buffer.add_char out base64_table.[b2 land 0x3f]
      else Buffer.add_char out '=';
      loop (index + 3))
  in
  loop 0;
  Buffer.contents out

let audio_data_base64 = function
  | A.Base64 value -> value
  | A.Bytes bytes -> base64_encode (Bytes.to_string bytes)

let client_event_json = function
  | Raw_client_event json -> Stdlib.Ok json
  | Session_update session ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "session.update"));
             ("session", Some (session_json session));
           ])
  | Input_audio_buffer_append audio ->
      Stdlib.Ok
        (Json.object_
           [
             ("type", Some (Json.string "input_audio_buffer.append"));
             ("audio", Some (Json.string (audio_data_base64 audio.A.data)));
           ])
  | Input_audio_buffer_commit ->
      Stdlib.Ok
        (Json.object_ [ ("type", Some (Json.string "input_audio_buffer.commit")) ])
  | Response_create ->
      Stdlib.Ok (Json.object_ [ ("type", Some (Json.string "response.create")) ])

let client_event_to_string event =
  match client_event_json event with
  | Stdlib.Ok json -> Stdlib.Ok (Json.to_string json)
  | Stdlib.Error _ as error -> error

let server_error_json raw json =
  let error = Json.object_member "error" json in
  let code = Option.bind error (Json.scalar_string_member "code") in
  let message =
    Option.bind error (Json.scalar_string_member "message")
    |> Option.value ~default:"OpenAI Realtime error"
  in
  Server_error { code; message; raw = Some raw }

let decode_server_event raw =
  match Json.parse raw with
  | Stdlib.Error message -> Server_decode_error { message; raw = Some raw }
  | Stdlib.Ok json -> (
      match Json.string_member "type" json with
      | Some "session.created" -> Session_created (Some raw)
      | Some "response.output_audio.delta" -> (
          match Json.string_member "delta" json with
          | Some delta -> Response_audio_delta delta
          | None -> Server_decode_error { message = "audio delta missing delta"; raw = Some raw })
      | Some "response.output_text.delta" -> (
          match Json.string_member "delta" json with
          | Some delta -> Response_text_delta delta
          | None -> Server_decode_error { message = "text delta missing delta"; raw = Some raw })
      | Some "response.done" | Some "response.completed" -> Response_done (Some raw)
      | Some "input_audio_buffer.committed" -> Input_audio_buffer_committed
      | Some "error" -> server_error_json raw json
      | type_ -> Raw_server_event { type_; raw })

type t = { ws : Eta_http.Ws.Client.t }

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> true
  | _ -> false

let percent_encode value =
  let out = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char out c
      else Buffer.add_string out (Printf.sprintf "%%%02X" (Char.code c)))
    value;
  Buffer.contents out

let ws_base_url ?(base_url = "wss://api.openai.com") () =
  let base_url = trim_trailing_slash base_url in
  if String.starts_with ~prefix:"https://" base_url then
    "wss://" ^ String.sub base_url 8 (String.length base_url - 8)
  else if String.starts_with ~prefix:"http://" base_url then
    "ws://" ^ String.sub base_url 7 (String.length base_url - 7)
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
  Eta_http.Ws.Client.connect ~headers:(websocket_headers ?safety_identifier api_key)
    ~sw ~net (realtime_url ?base_url ~model ())
  |> E.map (fun ws -> { ws })

let send_event t event : (unit, realtime_error) E.t =
  match client_event_to_string event with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok raw ->
      Eta_http.Ws.Client.send_text t.ws raw
      |> E.catch (fun error -> E.fail (widen_ws_error error))

let events t =
  Eta_http.Ws.Client.incoming t.ws
  |> Eta_stream.Stream.map (function
       | `Text raw -> decode_server_event raw
       | `Binary _ ->
           Server_decode_error
             { message = "OpenAI Realtime sent binary WebSocket message"; raw = None })

let close t = Eta_http.Ws.Client.close t.ws
