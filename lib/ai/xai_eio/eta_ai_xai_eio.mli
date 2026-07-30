(** Native Eio WebSocket transports for xAI. *)

module Responses_ws = Responses_ws

module Audio : sig
  module Speech_to_text = Streaming_stt
  module Text_to_speech = Streaming_tts
  module Realtime = Realtime
end

val capabilities : Eta_ai_xai.Capabilities.t
