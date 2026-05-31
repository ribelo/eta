(** OpenRouter Speech API ([POST /api/v1/audio/speech]). *)

module A = Common.A
module H = Common.H

let encode =
  Common.Codec.encode_speech ~instructions:false ~provider:"openrouter"

let decode_response (body, headers) =
  {
    A.Speech.content_type = H.Core.Header.get "content-type" headers;
    audio = body;
  }

let request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.post_request provider ~path:"/api/v1/audio/speech" ~api_key encode
    request

let run ?provider:custom_provider client ~api_key speech_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_binary ~max_bytes:(64 * 1024 * 1024) provider client
    (request ~provider ~api_key speech_request)
    decode_response
