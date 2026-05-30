(** OpenAI Speech API ([POST /v1/audio/speech]). *)

module A = Common.A
module H = Common.H
module Json = Common.Json

let encode (request : A.Speech.request) =
  if String.equal (String.trim request.input) "" then
    Common.unsupported "speech input must not be empty"
  else if String.equal (String.trim request.voice) "" then
    Common.unsupported "speech voice must not be empty"
  else
    let speed =
      match request.speed with
      | None -> Stdlib.Ok None
      | Some value -> (
          match Json.float value with
          | Some json -> Stdlib.Ok (Some json)
          | None -> Common.unsupported "speech speed must be finite")
    in
    match speed with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok speed ->
        Stdlib.Ok
          (Common.with_json_fields request.extra
             [
               ("model", Some (Json.string request.model));
               ("input", Some (Json.string request.input));
               ("voice", Some (Json.string request.voice));
               ( "response_format",
                 Option.map Json.string request.response_format );
               ("speed", speed);
               ("instructions", Option.map Json.string request.instructions);
             ]
          |> Json.to_string)

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
