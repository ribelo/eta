type availability = Available | Unavailable

type t = {
  responses_create : bool;
  responses_http_sse : bool;
  responses_websocket : bool;
  stored_responses : bool;
  response_compaction : bool;
  files : bool;
  collections_management : bool;
  collections_search : bool;
  model_catalogs : bool;
  unary_speech_to_text : bool;
  streaming_speech_to_text : bool;
  unary_text_to_speech : bool;
  streaming_text_to_speech : bool;
  realtime_speech : bool;
  built_in_voices : bool;
  custom_voice_discovery : bool;
  custom_voice_management : bool;
  live_translation : availability;
  phone_management : bool;
  call_control : bool;
}

val detailed : t
val shared : Eta_ai.capabilities
