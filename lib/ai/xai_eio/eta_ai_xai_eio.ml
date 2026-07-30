module Responses_ws = Responses_ws
module Realtime = Realtime
module Streaming_stt = Streaming_stt
module Streaming_tts = Streaming_tts

let capabilities : Eta_ai_xai.Capabilities.t =
  {
    Eta_ai_xai.Capabilities.detailed with
    responses_websocket = true;
    streaming_speech_to_text = true;
    streaming_text_to_speech = true;
  }
