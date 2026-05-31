(** OpenAI Audio Transcriptions API ([POST /v1/audio/transcriptions]).
    Includes the multipart/form-data body builder. *)

module A = Common.A
module H = Common.H
module Json = Common.Json

let decode_response raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      Stdlib.Ok
        {
          A.Transcription.text = Json.string_member "text" json;
          usage =
            Option.map Common.Codec.usage (Json.object_member "usage" json);
          raw = Some raw;
        }

let safe_disposition_value label value =
  if
    String.contains value '\r' || String.contains value '\n'
    || String.contains value '"'
  then
    Common.unsupported (label ^ " contains an invalid multipart character")
  else Stdlib.Ok value

let safe_header_value label value =
  if String.contains value '\r' || String.contains value '\n' then
    Common.unsupported
      (label ^ " contains an invalid multipart header character")
  else Stdlib.Ok value

let rec safe_extra_fields = function
  | [] -> Stdlib.Ok []
  | (name, value) :: rest -> (
      match safe_disposition_value "transcription field name" name with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok name -> (
          match safe_extra_fields rest with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok fields -> Stdlib.Ok ((name, value) :: fields)))

let multipart_boundary (file : A.binary_file) =
  "eta-ai-" ^ Digest.to_hex (Digest.bytes file.data)

let add_field buffer boundary name value =
  Buffer.add_string buffer ("--" ^ boundary ^ "\r\n");
  Buffer.add_string buffer
    ("Content-Disposition: form-data; name=\"" ^ name ^ "\"\r\n\r\n");
  Buffer.add_string buffer value;
  Buffer.add_string buffer "\r\n"

let multipart_body (request : A.Transcription.request) =
  match safe_disposition_value "transcription filename" request.file.filename with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok filename -> (
      match safe_header_value "transcription content type" request.file.content_type with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok content_type -> (
          match safe_extra_fields request.extra_fields with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok extra_fields ->
              let boundary = multipart_boundary request.file in
              let buffer = Buffer.create (Bytes.length request.file.data + 512) in
              add_field buffer boundary "model" request.model;
              Option.iter (add_field buffer boundary "language") request.language;
              Option.iter (add_field buffer boundary "prompt") request.prompt;
              Option.iter
                (add_field buffer boundary "response_format")
                request.response_format;
              Option.iter
                (fun value ->
                  add_field buffer boundary "temperature"
                    (Printf.sprintf "%.17g" value))
                request.temperature;
              List.iter
                (fun (name, value) -> add_field buffer boundary name value)
                extra_fields;
              Buffer.add_string buffer ("--" ^ boundary ^ "\r\n");
              Buffer.add_string buffer
                ("Content-Disposition: form-data; name=\"file\"; filename=\""
                ^ filename ^ "\"\r\n");
              Buffer.add_string buffer
                ("Content-Type: " ^ content_type ^ "\r\n\r\n");
              Buffer.add_bytes buffer request.file.data;
              Buffer.add_string buffer ("\r\n--" ^ boundary ^ "--\r\n");
              Stdlib.Ok (boundary, Bytes.of_string (Buffer.contents buffer))))

let multipart_request provider ~path api_key boundary body =
  let headers =
    provider.A.auth_headers api_key
    |> H.Core.Header.remove "content-type"
    |> H.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ boundary)
  in
  H.Request.make ~headers ~body:(H.Request.Fixed [ body ]) "POST"
    (Common.join_url provider.base_url path)

let request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  match multipart_body request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok (boundary, body) ->
      Stdlib.Ok
        (multipart_request provider ~path:"/v1/audio/transcriptions" api_key
           boundary body)

let run ?provider:custom_provider client ~api_key transcription_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.run_raw_decoded provider client
    (request ~provider ~api_key transcription_request)
    decode_response
