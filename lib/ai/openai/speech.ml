(** OpenAI Speech API ([POST /v1/audio/speech]). *)

module A = Common.A
module H = Common.H

type request = {
  model : A.model;
  input : string;
  voice : string;
  response_format : string option;
  speed : float option;
  instructions : string option;
  extra : (string * A.Json.t) list;
}

type result = {
  content_type : string option;
  audio : bytes;
}

type configuration = {
  model : A.model;
  instructions : string option;
  extra : (string * A.Json.t) list;
}

type request_construction = A.Audio.Text_to_speech.request

let of_eta_ai request = request

let response_format = function
  | A.Audio.Text_to_speech.Mp3 -> "mp3"
  | Wav -> "wav"
  | Pcm -> "pcm"

let configure configuration (request : request_construction) =
  if A.Json_helpers.is_blank configuration.model then
    Common.invalid_request "speech model must not be empty"
  else
    let request =
      {
        model = configuration.model;
        input = request.text;
        voice = request.voice;
        response_format = Option.map response_format request.encoding;
        speed = request.speed;
        instructions = configuration.instructions;
        extra = configuration.extra;
      }
    in
    match
      Common.Codec.encode_speech_lossless ~model:request.model
        ~input:request.input ~voice:request.voice
        ?response_format:request.response_format ?speed:request.speed
        ?speech_instructions:request.instructions ~extra:request.extra ()
    with
    | Stdlib.Ok _ -> Stdlib.Ok request
    | Stdlib.Error failure -> Stdlib.Error (Common.Error.of_codec_failure failure)

let to_eta_ai (result : result) : A.Audio.Text_to_speech.result =
  { content_type = result.content_type; audio = result.audio }

let encode (request : request) =
  match
    Common.Codec.encode_speech_lossless ~model:request.model ~input:request.input
      ~voice:request.voice ?response_format:request.response_format
      ?speed:request.speed ?speech_instructions:request.instructions
      ~extra:request.extra ()
  with
  | Stdlib.Ok raw -> Stdlib.Ok raw
  | Stdlib.Error failure -> Stdlib.Error (Common.Error.of_codec_failure failure)

let decode_response (body, headers) =
  {
    content_type = H.Core.Header.get "content-type" headers;
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

let create = run
