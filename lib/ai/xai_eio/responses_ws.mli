(** Eio transport for xAI Responses WebSocket mode. *)

type provider_code =
  | Previous_response_not_found
  | Websocket_connection_limit_reached
  | Other of string

type provider_error = {
  code : provider_code option;
  message : string option;
  raw : Eta_ai.raw_json;
}

type error =
  [ Eta_http_eio.Ws.Client.ws_error
  | `Decode of string
  | `Invalid_request of string
  | `Provider_error of provider_error
  | `Xai_error of Eta_ai_xai.Error.t
  ]
type t

val connect :
  ?ca_file:string ->
  ?max_age:Eta.Duration.t ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Eta_ai.api_key ->
  unit ->
  (t, error) Eta.Effect.t

val create :
  t -> Eta_ai_xai.Responses.request -> (unit, error) Eta.Effect.t
val warmup :
  t -> Eta_ai_xai.Responses.request -> (unit, error) Eta.Effect.t
val read_event :
  t -> (Eta_ai_xai.Responses.stream_event option, error) Eta.Effect.t
val close : t -> (unit, error) Eta.Effect.t
