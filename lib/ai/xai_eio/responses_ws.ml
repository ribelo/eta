module E = Eta.Effect
module Json = Eta_ai.Json
module Responses = Eta_ai_xai.Responses

type provider_code =
  | Previous_response_not_found
  | Websocket_connection_limit_reached
  | Other of string

type provider_error = {
  code : provider_code option;
  message : string option;
  raw : Eta_ai.raw_json;
}

type error = [ Common.error | `Provider_error of provider_error ]
type t = { connection : Common.t }

let widen_common eff =
  E.bind_error (fun (error : Common.error) -> E.fail (error :> error)) eff

let url ?(endpoint = Eta_ai_xai.Endpoint.default_inference) () =
  Result.map
    (fun base -> base ^ "/v1/responses")
    (Common.ws_base_url endpoint)

let close_with ?error_type t =
  widen_common (Common.close ?error_type t.connection)

let close t = close_with t

let valid_max_age value =
  Eta.Duration.compare value Eta.Duration.zero > 0
  && Eta.Duration.compare value (Eta.Duration.minutes 25) <= 0

let start_lifetime ~max_age t =
  Eta.Spi.daemon (E.sleep max_age |> E.bind (fun () -> close t))
  |> E.map (fun () -> t)

let make ~max_age connection =
  start_lifetime ~max_age { connection }

let connect ?ca_file ?(max_age = Eta.Duration.minutes 25) ~sw ~net ~api_key () =
  if not (valid_max_age max_age) then
    E.fail
      (`Invalid_request
        "Responses WebSocket max_age must be greater than zero and at most 25 minutes")
  else
    match url () with
    | Error error -> E.fail (error :> error)
    | Ok raw_url ->
        Common.connect ?ca_file ~operation:"responses.websocket" ~sw ~net
          ~headers:(Common.headers api_key) raw_url
        |> widen_common
        |> E.bind (make ~max_age)

let connect_on_flow ?key ?(max_age = Eta.Duration.minutes 25) ~sw ~flow
    ~api_key url =
  if not (valid_max_age max_age) then
    E.fail
      (`Invalid_request
        "Responses WebSocket max_age must be greater than zero and at most 25 minutes")
  else
    Common.connect_on_flow ?key ~operation:"responses.websocket" ~sw ~flow
      ~headers:(Common.headers api_key) url
    |> widen_common
    |> E.bind (make ~max_age)

let send_request ?generate t request =
  match Responses.encode_websocket_create ?generate request with
  | Error error -> E.fail (`Invalid_request (Common.xai_error_message error))
  | Ok raw ->
      Common.record_attrs t.connection
        [
          ("gen_ai.request.model", request.Responses.model);
          ("gen_ai.request.stream", "true");
        ];
      widen_common (Common.send_text t.connection raw)

let create t request = send_request t request
let warmup t request = send_request ~generate:false t request

let provider_code = function
  | "previous_response_not_found" -> Previous_response_not_found
  | "websocket_connection_limit_reached" ->
      Websocket_connection_limit_reached
  | value -> Other value

let decode_error raw json =
  let payload =
    Option.value ~default:json (Json.object_member "error" json)
  in
  {
    code =
      Option.map provider_code
        (Json.scalar_string_member "code" payload);
    message = Json.scalar_string_member "message" payload;
    raw;
  }

let decode_event raw =
  match Json.parse raw with
  | Error message -> Error (`Decode message)
  | Ok json ->
      if Json.string_member "type" json = Some "error" then
        Error (`Provider_error (decode_error raw json))
      else
        let response =
          Option.value ~default:json (Json.object_member "response" json)
        in
        match
          Responses.decode_stream_event { Eta_ai.event = None; data = raw }
        with
        | Ok event -> Ok (event, Json.string_member "id" response)
        | Error error ->
            Error (`Decode (Common.xai_error_message error))

let error_code_string = function
  | Previous_response_not_found -> "previous_response_not_found"
  | Websocket_connection_limit_reached ->
      "websocket_connection_limit_reached"
  | Other value -> value

let read_event t =
  (Common.read_message t.connection |> widen_common)
  |> E.bind (function
       | None -> E.pure None
       | Some (`Binary _) ->
           E.fail (`Decode "Responses WebSocket emitted a binary message")
           |> E.finally (close_with ~error_type:"decode_error" t)
       | Some (`Text raw) -> (
           match decode_event raw with
           | Ok (event, response_id) ->
               Option.iter
                 (fun id ->
                   Common.record_attrs t.connection
                     [ ("gen_ai.response.id", id) ])
                 response_id;
               E.pure (Some event)
           | Error (`Provider_error error) ->
               let error_type =
                 Option.map error_code_string error.code
                 |> Option.value ~default:"provider_error"
               in
               Common.record_attrs t.connection [ ("error.type", error_type) ];
               let failure = E.fail (`Provider_error error) in
               (match error.code with
               | Some Websocket_connection_limit_reached ->
                   failure |> E.finally (close_with ~error_type t)
               | _ -> failure)
           | Error error ->
               E.fail error
               |> E.finally (close_with ~error_type:"decode_error" t)))
