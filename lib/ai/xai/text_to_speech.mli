(** Unary xAI text-to-speech. Streaming transport belongs to eta_ai_xai_eio. *)

type codec = Mp3 | Wav | Pcm | Mulaw | Alaw

type output_format = {
  codec : codec;
  sample_rate : int option;
  bit_rate : int option;
}

type request = {
  text : string;
  language : string;
  voice_id : string option;
  output_format : output_format option;
  speed : float option;
  optimize_streaming_latency : int option;
  text_normalization : bool option;
  with_timestamps : bool;
}

type raw_audio = {
  content_type : string option;
  bytes : bytes;
}

type timestamped_audio = {
  audio : bytes;
  content_type : string option;
  duration : float option;
  graph_chars : string list;
  graph_times : Eta_ai.Json.t;
  raw : Eta_ai.raw_json;
}

type response =
  | Raw_audio of raw_audio
  | Timestamped_audio of timestamped_audio

val request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  request ->
  (Eta_http.Request.t, Xai_error.t) result

val synthesize :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  request ->
  (response, Xai_error.t) Eta.Effect.t
