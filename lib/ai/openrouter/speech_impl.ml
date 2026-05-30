(** OpenRouter Speech API ([POST /api/v1/audio/speech]). *)

module A = Common.A
module H = Common.H
module Json = Common.Json

let encode (request : A.Speech.request) =
  if String.equal (String.trim request.input) "" then
    Common.invalid_routing "speech input must not be empty"
  else if String.equal (String.trim request.voice) "" then
    Common.invalid_routing "speech voice must not be empty"
  else if Option.is_some request.instructions then
    Common.invalid_routing "speech instructions"
  else
    let speed = Option.bind request.speed Json.float in
    if Option.is_some request.speed && Option.is_none speed then
      Common.invalid_routing "speech speed must be finite"
    else
      Stdlib.Ok
        (Common.with_json_fields request.extra
           [
             ("model", Some (Json.string request.model));
             ("input", Some (Json.string request.input));
             ("voice", Some (Json.string request.voice));
             ("response_format", Option.map Json.string request.response_format);
             ("speed", speed);
           ]
        |> Json.to_string)

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
