(** OpenRouter Transcription API ([POST /api/v1/audio/transcriptions]).
    Unlike OpenAI's multipart upload, OpenRouter expects the audio embedded
    as base64-encoded JSON. *)

module A = Common.A
module E = Common.E
module Json = Common.Json
module Codec = Common.Codec

let format_of_file (file : A.binary_file) =
  let content_type = String.lowercase_ascii file.content_type in
  let filename = String.lowercase_ascii file.filename in
  let has value =
    String.ends_with ~suffix:("/" ^ value) content_type
    || String.ends_with ~suffix:("." ^ value) filename
    || String.ends_with ~suffix:("-" ^ value) content_type
  in
  if has "wav" then Stdlib.Ok "wav"
  else if has "mp3" || String.equal content_type "audio/mpeg" then
    Stdlib.Ok "mp3"
  else if has "flac" then Stdlib.Ok "flac"
  else if has "m4a" || String.equal content_type "audio/mp4" then
    Stdlib.Ok "m4a"
  else if has "ogg" then Stdlib.Ok "ogg"
  else if has "webm" then Stdlib.Ok "webm"
  else if has "aac" then Stdlib.Ok "aac"
  else
    Common.invalid_routing
      "transcription file content_type must identify a supported audio format"

let encode (request : A.Transcription.request) =
  if Option.is_some request.prompt then
    Common.invalid_routing "transcription prompt"
  else if Option.is_some request.response_format then
    Common.invalid_routing "transcription response_format"
  else if request.extra_fields <> [] then
    Common.invalid_routing "transcription extra fields"
  else
    match format_of_file request.file with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok format ->
        let data = Common.base64_encode (Bytes.to_string request.file.data) in
        let temperature = Option.bind request.temperature Json.float in
        if Option.is_some request.temperature && Option.is_none temperature
        then Common.invalid_routing "transcription temperature must be finite"
        else
          Stdlib.Ok
            (Json.object_
               [
                 ("model", Some (Json.string request.model));
                 ( "input_audio",
                   Some
                     (Json.object_
                        [
                          ("data", Some (Json.string data));
                          ("format", Some (Json.string format));
                        ]) );
                 ("language", Option.map Json.string request.language);
                 ("temperature", temperature);
               ]
            |> Json.to_string)

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      Stdlib.Ok
        {
          A.Transcription.text = Json.string_member "text" json;
          usage = Option.map Codec.usage (Json.object_member "usage" json);
          raw = Some raw;
        }

let request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (A.provider_post_request provider
           ~path:"/api/v1/audio/transcriptions" api_key raw)

let run ?provider:custom_provider client ~api_key transcription_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match request ~provider ~api_key transcription_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)
