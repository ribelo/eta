(** OpenRouter Transcription API ([POST /api/v1/audio/transcriptions]).
    Unlike OpenAI's multipart upload, OpenRouter expects the audio embedded
    as base64-encoded JSON. *)

module A = Common.A
module Json = Common.Json
module Codec = Common.Codec

let[@zero_alloc] ends_with_sep_token_ci value sep token =
  let value_len = String.length value in
  let token_len = String.length token in
  let suffix_len = token_len + 1 in
  if value_len < suffix_len then false
  else
    let start = value_len - suffix_len in
    Char.equal (String.unsafe_get value start) sep
    &&
    let index = ref 0 in
    while
      !index < token_len
      && Eta.String_helpers.ascii_equal_ci
           (String.unsafe_get value (start + 1 + !index))
           (String.unsafe_get token !index)
    do
      incr index
    done;
    !index = token_len

let format_of_file (file : A.binary_file) =
  let has suffix =
    ends_with_sep_token_ci file.content_type '/' suffix
    || ends_with_sep_token_ci file.filename '.' suffix
    || ends_with_sep_token_ci file.content_type '-' suffix
  in
  if has "wav" then Stdlib.Ok "wav"
  else if
    has "mp3"
    || Eta.String_helpers.ends_with_ascii_ci file.content_type
         ~suffix:"audio/mpeg"
  then
    Stdlib.Ok "mp3"
  else if has "flac" then Stdlib.Ok "flac"
  else if
    has "m4a"
    || Eta.String_helpers.ends_with_ascii_ci file.content_type
         ~suffix:"audio/mp4"
  then
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
  let provider = Common.default_provider Common.provider custom_provider in
  Common.post_request provider ~path:"/api/v1/audio/transcriptions" ~api_key
    encode request

let run ?provider:custom_provider client ~api_key transcription_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_raw_decoded provider client
    (request ~provider ~api_key transcription_request)
    decode
