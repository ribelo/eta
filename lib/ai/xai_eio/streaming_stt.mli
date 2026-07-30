(** xAI streaming speech-to-text WebSocket protocol. *)

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

val default_config : config

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

val send_audio : t -> bytes -> (unit, error) Eta.Effect.t
val finalize : ?channel:int -> t -> (unit, error) Eta.Effect.t
val audio_done : t -> (unit, error) Eta.Effect.t
val read_event : t -> (event option, error) Eta.Effect.t
val close : t -> (unit, error) Eta.Effect.t
