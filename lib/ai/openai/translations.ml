(** OpenAI completed-audio translation into English. *)

module A = Common.A
module E = Eta.Effect
module H = Eta_http
module M = H.Multipart

let ( let* ) = Result.bind
let defer thunk = E.sync thunk |> E.bind Fun.id

let multipart_error ~label error =
  Openai_error.Invalid_request (label ^ " " ^ M.error_message error)

let multipart_source source =
  {
    M.length = A.Audio.known_length source;
    replayability =
      (match A.Audio.replayability source with
      | A.Audio.Replayable -> M.Replayable
      | A.Audio.One_shot -> M.One_shot);
    open_reader = (fun () -> A.Audio.open_pull source);
  }

let multipart_file (upload : A.Audio.upload) =
  M.File
    {
      name = "file";
      filename = upload.filename;
      content_type = upload.content_type;
      data = M.Pull (multipart_source upload.source);
    }

let multipart_text (name, value) = M.Text { name; value }

let check_multipart ~label parts =
  M.make parts
  |> Result.map_error (multipart_error ~label)
  |> Result.map ignore

type response_format =
  | Json
  | Text
  | Srt
  | Verbose_json
  | Vtt
  | Other_format of string

type request = {
  file : A.Audio.upload;
  prompt : string option;
  response_format : response_format option;
  temperature : float option;
  extra_fields : (string * string) list;
}

type segment = Transcriptions.segment = {
  id : int;
  seek : int;
  start : float;
  end_ : float;
  text : string;
  tokens : int list;
  temperature : float;
  avg_logprob : float;
  compression_ratio : float;
  no_speech_prob : float;
  raw : A.Json.t;
}

type result =
  | Json_result of {
      text : string;
      raw : A.Json.t;
    }
  | Text_result of string
  | Srt_result of string
  | Verbose_json_result of {
      language : string;
      duration : float;
      text : string;
      segments : segment list option;
      raw : A.Json.t;
    }
  | Vtt_result of string
  | Other_result of {
      format : string;
      body : string;
    }

let response_format_to_string = function
  | Json -> "json"
  | Text -> "text"
  | Srt -> "srt"
  | Verbose_json -> "verbose_json"
  | Vtt -> "vtt"
  | Other_format value -> value

type canonical_format =
  | Canonical_json
  | Canonical_text
  | Canonical_srt
  | Canonical_verbose_json
  | Canonical_vtt
  | Canonical_unknown of string

let canonical_response_format = function
  | None | Some Json -> Canonical_json
  | Some Text -> Canonical_text
  | Some Srt -> Canonical_srt
  | Some Verbose_json -> Canonical_verbose_json
  | Some Vtt -> Canonical_vtt
  | Some (Other_format "json") -> Canonical_json
  | Some (Other_format "text") -> Canonical_text
  | Some (Other_format "srt") -> Canonical_srt
  | Some (Other_format "verbose_json") -> Canonical_verbose_json
  | Some (Other_format "vtt") -> Canonical_vtt
  | Some (Other_format value) -> Canonical_unknown value

let canonical_format_to_string = function
  | Canonical_json -> "json"
  | Canonical_text -> "text"
  | Canonical_srt -> "srt"
  | Canonical_verbose_json -> "verbose_json"
  | Canonical_vtt -> "vtt"
  | Canonical_unknown value -> value

let owned_fields =
  [ "file"; "model"; "prompt"; "response_format"; "temperature" ]

let canonical_field name =
  let length = String.length name in
  if length >= 2 && String.sub name (length - 2) 2 = "[]" then
    String.sub name 0 (length - 2)
  else name

let validate request =
  let format =
    canonical_response_format request.response_format
    |> canonical_format_to_string
  in
  let* () =
    if A.Json_helpers.is_blank format then
      Common.invalid_request "translation response format must not be empty"
    else Ok ()
  in
  let* () =
    check_multipart ~label:"translation" [ multipart_file request.file ]
  in
  let* () =
    match request.extra_fields with
    | [] -> Ok ()
    | fields ->
        check_multipart ~label:"translation"
          (List.map multipart_text fields @ [ multipart_file request.file ])
  in
  let* () =
    if A.Json_helpers.is_blank request.file.filename then
      Common.invalid_request "translation filename must not be empty"
    else if A.Json_helpers.is_blank request.file.content_type then
      Common.invalid_request "translation content type must not be empty"
    else Ok ()
  in
  let* () =
    Audio_upload_limit.validate ~label:"translation" request.file.source
  in
  let* () =
    match request.temperature with
    | Some value
      when (not (Float.is_finite value)) || value < 0.0 || value > 1.0 ->
        Common.invalid_request
          "translation temperature must be finite and between 0 and 1"
    | None | Some _ -> Ok ()
  in
  match
    List.find_opt
      (fun (name, _) -> List.mem (canonical_field name) owned_fields)
      request.extra_fields
  with
  | Some (name, _) ->
      Common.invalid_request ("extra field collides with owned field " ^ name)
  | None -> Ok ()

let request ~file ?prompt ?response_format ?temperature ?(extra_fields = []) () =
  let request = { file; prompt; response_format; temperature; extra_fields } in
  Result.map (fun () -> request) (validate request)

let decode_response response_format raw =
  match canonical_response_format response_format with
  | Canonical_text -> Ok (Text_result raw)
  | Canonical_srt -> Ok (Srt_result raw)
  | Canonical_vtt -> Ok (Vtt_result raw)
  | Canonical_json ->
      let* json = Transcriptions.object_body raw in
      let* text =
        Transcriptions.required "text" Transcriptions.as_string raw json
      in
      Ok (Json_result { text; raw = json })
  | Canonical_verbose_json ->
      let* json = Transcriptions.object_body raw in
      let* language =
        Transcriptions.required "language" Transcriptions.as_string raw json
      in
      let* duration =
        Transcriptions.required "duration" Transcriptions.as_float raw json
      in
      let* text =
        Transcriptions.required "text" Transcriptions.as_string raw json
      in
      let* segments =
        Transcriptions.optional_list "segments" Transcriptions.segment raw json
      in
      if not (String.equal language "english") then
        Transcriptions.decode_error raw
          "translation verbose language must be english"
      else
        Ok
          (Verbose_json_result
             { language; duration; text; segments; raw = json })
  | Canonical_unknown format ->
      Ok (Other_result { format; body = raw })

let multipart_fields request =
  let optional name encode value =
    Option.to_list
      (Option.map (fun value -> (name, encode value)) value)
  in
  [ ("model", "whisper-1") ]
  @ optional "prompt" Fun.id request.prompt
  @ optional "response_format" response_format_to_string
      request.response_format
  @ optional "temperature" (Printf.sprintf "%.17g") request.temperature
  @ request.extra_fields

let http_request ?provider:custom_provider ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  let* () = validate request in
  let* multipart =
    M.make
      (List.map multipart_text (multipart_fields request)
      @ [ multipart_file request.file ])
    |> Result.map_error (multipart_error ~label:"translation")
  in
  let headers =
    provider.A.auth_headers api_key
    |> H.Core.Header.remove "accept"
    |> H.Core.Header.remove "content-type"
    |> H.Core.Header.remove "content-length"
    |> H.Core.Header.unsafe_add "Content-Type"
         ("multipart/form-data; boundary=" ^ multipart.boundary)
  in
  Ok
    (H.Request.make ~headers ~body:multipart.body "POST"
       (Common.join_url provider.A.base_url "/v1/audio/translations"))

let create ?provider:custom_provider client ~api_key request =
  let provider = Common.default_provider Common.provider custom_provider in
  let format =
    canonical_response_format request.response_format
    |> canonical_format_to_string
  in
  defer (fun () ->
      Common.run_raw_decoded ~max_bytes:max_int provider client
        (http_request ~provider ~api_key request)
        (decode_response request.response_format))
  |> Common.with_provider_span provider ~operation:"translation.create"
       ~model:"whisper-1"
       ~attrs:
         [
           ("eta_ai.request.response_format", format);
           ("eta_ai.request.stream", "false");
         ]
