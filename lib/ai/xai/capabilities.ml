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

let detailed =
  {
    responses_create = true;
    responses_http_sse = true;
    responses_websocket = false;
    stored_responses = true;
    response_compaction = true;
    files = true;
    collections_management = true;
    collections_search = true;
    model_catalogs = true;
    unary_speech_to_text = true;
    streaming_speech_to_text = false;
    unary_text_to_speech = true;
    streaming_text_to_speech = false;
    realtime_speech = true;
    built_in_voices = true;
    custom_voice_discovery = true;
    custom_voice_management = false;
    live_translation = Unavailable;
    phone_management = false;
    call_control = false;
  }

let shared =
  {
    Eta_ai.streaming = detailed.responses_http_sse;
    tools = true;
    tool_choice = true;
    structured_outputs = true;
    text = true;
    image_input = true;
    audio_input = false;
    video_input = false;
    embeddings = false;
    image_generation = true;
    speech = detailed.unary_text_to_speech;
    transcription = detailed.unary_speech_to_text;
    rerank = false;
    video_generation = false;
  }
