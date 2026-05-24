module Codec = Eta_ai_openai_codec

let decode_event event = Codec.decode_stream_event ~provider:"openai" event
