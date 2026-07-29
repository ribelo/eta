(** Unary xAI speech-to-text. Streaming transport belongs to eta_ai_xai_eio. *)

type source =
  | File of Eta_ai.binary_file
  | Url of string

type raw_audio_format = Pcm | Mulaw | Alaw

type request = {
  source : source;
  audio_format : raw_audio_format option;
  sample_rate : int option;
  language : string option;
  format : bool option;
  multichannel : bool option;
  channels : int option;
  diarize : bool option;
  keyterm : string list;
  filler_words : bool option;
  vad_threshold : float option;
}

type word = {
  text : string;
  start : float option;
  end_ : float option;
  confidence : float option;
  speaker : int option;
  raw : Eta_ai.Json.t;
}

type channel = {
  index : int option;
  text : string option;
  words : word list;
  raw : Eta_ai.Json.t;
}

type response = {
  text : string;
  language : string option;
  duration : float option;
  words : word list;
  channels : channel list;
  raw : Eta_ai.raw_json;
}

val request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  request ->
  (Eta_http.Request.t, Xai_error.t) result

val decode_response : Eta_ai.raw_json -> (response, Xai_error.t) result

val transcribe :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  request ->
  (response, Xai_error.t) Eta.Effect.t
