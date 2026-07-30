(** xAI streaming text-to-speech WebSocket protocol. *)

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

type error =
  [ Eta_http_eio.Ws.Client.ws_error
  | `Decode of string
  | `Invalid_request of string
  | `Xai_error of Eta_ai_xai.Error.t
  ]
type t

val connect :
  ?ca_file:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  api_key:Eta_ai.api_key ->
  config ->
  (t, error) Eta.Effect.t

val text_delta : t -> string -> (unit, error) Eta.Effect.t
val text_done : t -> (unit, error) Eta.Effect.t
val text_clear : t -> (unit, error) Eta.Effect.t
val read_event : t -> (event option, error) Eta.Effect.t
val close : t -> (unit, error) Eta.Effect.t
