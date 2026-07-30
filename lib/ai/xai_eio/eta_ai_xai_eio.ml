module Responses_ws = Responses_ws

module Audio = struct
  module Speech_to_text = Streaming_stt
  module Text_to_speech = Streaming_tts
  module Realtime = Realtime
end

let capabilities : Eta_ai_xai.Capabilities.t =
  {
    Eta_ai_xai.Capabilities.detailed with
    responses_websocket = true;
    streaming_speech_to_text = true;
    streaming_text_to_speech = true;
  }
