(** OpenAI Audio Transcriptions API ([POST /v1/audio/transcriptions]).
    Includes the multipart/form-data body builder. *)

module A = Common.A
module H = Common.H
module Json = Common.Json

type request = {
  model : A.model;
  file : A.Audio.upload;
  language : string option;
  prompt : string option;
  response_format : string option;
  temperature : float option;
  extra_fields : (string * string) list;
}

type result = {
  text : string option;
  language : string option;
  duration_s : float option;
  usage : A.usage option;
  raw : A.raw_json option;
}

(* [duration] is published as a JSON number by the verbose response format. *)
let duration_seconds json =
  match Json.member "duration" json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some _ | None -> None

type configuration = {
  model : A.model;
  prompt : string option;
  response_format : string option;
  temperature : float option;
  extra_fields : (string * string) list;
}

type request_construction = A.Audio.Speech_to_text.request

let of_eta_ai request = request

let configure configuration (request : request_construction) =
  if A.Json_helpers.is_blank configuration.model then
    Common.invalid_request "transcription model must not be empty"
  else
    Stdlib.Ok
      {
        model = configuration.model;
        file = request.upload;
        language = request.language;
        prompt = configuration.prompt;
        response_format = configuration.response_format;
        temperature = configuration.temperature;
        extra_fields = configuration.extra_fields;
      }

let to_eta_ai (result : result) : A.Audio.Speech_to_text.result =
  {
    text = result.text;
    language = result.language;
    duration_s = result.duration_s;
  }

let decode_response raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json ->
      Stdlib.Ok
        {
          text = Json.string_member "text" json;
          language = Json.string_member "language" json;
          duration_s = duration_seconds json;
          usage =
            Option.map Common.Codec.usage (Json.object_member "usage" json);
          raw = Some raw;
        }

let safe_disposition_value label value =
  if
    String.contains value '\r' || String.contains value '\n'
    || String.contains value '"'
  then
    Common.invalid_request (label ^ " contains an invalid multipart character")
  else Stdlib.Ok value

let safe_header_value label value =
  if String.contains value '\r' || String.contains value '\n' then
    Common.invalid_request
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

let[@zero_alloc] string_has_substring_at value ~needle index needle_len =
  let offset = ref 0 in
  while
    !offset < needle_len
    && Char.equal
         (String.unsafe_get value (index + !offset))
         (String.unsafe_get needle !offset)
  do
    incr offset
  done;
  !offset = needle_len

let[@zero_alloc] contains_substring value ~needle =
  let needle_len = String.length needle in
  let value_len = String.length value in
  if needle_len = 0 then true
  else (
    let stop = value_len - needle_len in
    let index = ref 0 in
    let found = ref false in
    while (not !found) && !index <= stop do
      found := string_has_substring_at value ~needle !index needle_len;
      incr index
    done;
    !found)

let read_upload source =
  let buffer = Buffer.create 4096 in
  let pull = A.Audio.open_pull source in
  let rec loop () =
    match pull () with
    | None -> Stdlib.Ok (Bytes.of_string (Buffer.contents buffer))
    | Some chunk ->
        Buffer.add_bytes buffer chunk;
        loop ()
    | exception exn ->
        Common.invalid_request
          ("transcription upload source failed: " ^ Printexc.to_string exn)
  in
  loop ()

let multipart_boundary data strings =
  let base = "eta-ai-" ^ Digest.to_hex (Digest.bytes data) in
  let collides boundary =
    contains_substring (Bytes.unsafe_to_string data) ~needle:boundary
    || List.exists (contains_substring ~needle:boundary) strings
  in
  let rec loop suffix =
    let boundary =
      if suffix = 0 then base else base ^ "-" ^ string_of_int suffix
    in
    if collides boundary then loop (suffix + 1) else boundary
  in
  loop 0

let add_field buffer boundary name value =
  Buffer.add_string buffer ("--" ^ boundary ^ "\r\n");
  Buffer.add_string buffer
    ("Content-Disposition: form-data; name=\"" ^ name ^ "\"\r\n\r\n");
  Buffer.add_string buffer value;
  Buffer.add_string buffer "\r\n"

let multipart_body (request : request) =
  match safe_disposition_value "transcription filename" request.file.filename with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok filename -> (
      match safe_header_value "transcription content type" request.file.content_type with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok content_type -> (
          match read_upload request.file.source with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok file_data -> (
              match safe_extra_fields request.extra_fields with
              | Stdlib.Error _ as error -> error
              | Stdlib.Ok extra_fields ->
              let temperature =
                Option.map (Printf.sprintf "%.17g") request.temperature
              in
              let add_optional name value fields =
                match value with
                | Some value -> value :: name :: fields
                | None -> fields
              in
              let fields =
                [ "file"; request.model; "model"; content_type; filename ]
                |> add_optional "language" request.language
                |> add_optional "prompt" request.prompt
                |> add_optional "response_format" request.response_format
                |> add_optional "temperature" temperature
              in
              let fields =
                List.fold_left
                  (fun fields (name, value) -> value :: name :: fields)
                  fields extra_fields
              in
              let boundary =
                multipart_boundary file_data (List.rev fields)
              in
              let buffer = Buffer.create (Bytes.length file_data + 512) in
              add_field buffer boundary "model" request.model;
              Option.iter (add_field buffer boundary "language") request.language;
              Option.iter (add_field buffer boundary "prompt") request.prompt;
              Option.iter
                (add_field buffer boundary "response_format")
                request.response_format;
              Option.iter (add_field buffer boundary "temperature") temperature;
              List.iter
                (fun (name, value) -> add_field buffer boundary name value)
                extra_fields;
              Buffer.add_string buffer ("--" ^ boundary ^ "\r\n");
              Buffer.add_string buffer
                ("Content-Disposition: form-data; name=\"file\"; filename=\""
                ^ filename ^ "\"\r\n");
              Buffer.add_string buffer
                ("Content-Type: " ^ content_type ^ "\r\n\r\n");
              Buffer.add_bytes buffer file_data;
              Buffer.add_string buffer ("\r\n--" ^ boundary ^ "--\r\n");
                  Stdlib.Ok
                    (boundary, Bytes.of_string (Buffer.contents buffer)))))

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

let create = run
