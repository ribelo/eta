(** OpenRouter Speech API ([POST /api/v1/audio/speech]). *)

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

type result = A.Audio.Text_to_speech.result = {
  content_type : string option;
  audio : bytes;
}

type configuration = {
  model : A.model;
  extra : (string * A.Json.t) list;
}

type request_construction = A.Audio.Text_to_speech.request

let of_eta_ai request = request

let response_format = function
  | A.Audio.Text_to_speech.Mp3 -> "mp3"
  | Wav -> "wav"
  | Pcm -> "pcm"

let encode (request : request) =
  Common.Codec.encode_speech ~instructions:false ~provider:"openrouter"
    ~model:request.model ~input:request.input ~voice:request.voice
    ?response_format:request.response_format ?speed:request.speed
    ?speech_instructions:request.instructions ~extra:request.extra ()

let configure configuration (construction : request_construction) =
  let request =
    {
      model = configuration.model;
      input = construction.text;
      voice = construction.voice;
      response_format = Option.map response_format construction.encoding;
      speed = construction.speed;
      instructions = None;
      extra = configuration.extra;
    }
  in
  Result.map (fun _ -> request) (encode request)

let to_eta_ai result = result

let decode_response (body, headers) =
  {
    content_type = H.Core.Header.get "content-type" headers;
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

let create = run
