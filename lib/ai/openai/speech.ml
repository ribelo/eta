(** OpenAI Speech API ([POST /v1/audio/speech]). *)

module A = Common.A
module H = Common.H

let encode request =
  match Common.Codec.encode_speech_lossless request with
  | Stdlib.Ok raw -> Stdlib.Ok raw
  | Stdlib.Error failure -> Stdlib.Error (Common.Error.of_codec_failure failure)

let decode_response (body, headers) =
  {
    A.Speech.content_type = H.Core.Header.get "content-type" headers;
    audio = body;
  }

let request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.post_request provider ~path:"/v1/audio/speech" ~api_key encode request

let run ?provider:custom_provider client ~api_key speech_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_binary ~max_bytes:(64 * 1024 * 1024) provider client
    (request ~provider ~api_key speech_request)
    decode_response
