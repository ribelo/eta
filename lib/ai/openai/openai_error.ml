module A = Eta_ai
module Json = A.Json

type provider_payload = {
  message : string option;
  type_ : string option;
  param : A.Json.t option;
  code : A.Json.t option;
  raw : A.Json.t;
  full : A.Json.t;
}

type t =
  | Http of Eta_http.Error.t
  | Provider of provider_payload A.Provider.Error.http_response
  | Unknown_response of unit A.Provider.Error.http_response
  | Provider_response of {
      status : int option;
      message : string option;
      type_ : string option;
      param : A.Json.t option;
      code : A.Json.t option;
      raw : A.Json.t option;
      full : A.Json.t option;
      raw_body : A.raw_json option;
    }
  | Decode of {
      message : string;
      raw_body : A.raw_json option;
    }
  | Invalid_request of string
  | Concurrent_use of string
  | Limit_exceeded of {
      kind : string;
      limit : int;
      actual : int;
    }
  | Unsupported of string
  | Invalid_tool of {
      name : string;
      message : string;
    }

let code_string = function
  | None -> None
  | Some (`String value) -> Some value
  | Some (`Int value) -> Some (string_of_int value)
  | Some (`Intlit value) -> Some value
  | Some (`Float value) -> Some (Printf.sprintf "%.17g" value)
  | Some (`Bool true) -> Some "true"
  | Some (`Bool false) -> Some "false"
  | Some `Null -> None
  | Some json -> Some (Json.compact json)

let payload_of_json full =
  let error =
    match Json.object_member "error" full with
    | Some error -> error
    | None -> full
  in
  {
    message = Json.scalar_string_member "message" error;
    type_ = Json.scalar_string_member "type" error;
    param = Json.member "param" error;
    code = Json.member "code" error;
    raw = error;
    full;
  }

let decode ~status ~headers raw_body =
  match Json.parse raw_body with
  | Ok json ->
      Provider
        {
          status;
          headers;
          payload = Some (payload_of_json json);
          raw_body;
        }
  | Error _ -> Unknown_response { status; headers; payload = None; raw_body }

let of_wire_payload ?status ?raw_body (payload : Eta_ai_openai_codec.wire_error_payload)
    =
  Provider_response
    {
      status;
      message = payload.message;
      type_ = payload.type_;
      param = payload.param;
      code = payload.code;
      raw = Some payload.raw;
      full = Some payload.full;
      raw_body;
    }

let of_codec_failure = function
  | Eta_ai_openai_codec.Invalid_request message -> Invalid_request message
  | Eta_ai_openai_codec.Unsupported feature -> Unsupported feature
  | Eta_ai_openai_codec.Invalid_tool { name; message } ->
      Invalid_tool { name; message }
  | Eta_ai_openai_codec.Decode { message; raw_body } ->
      Decode { message; raw_body }

let of_ai_error = function
  | A.Eta_http_error error -> Http error
  | A.Invalid_request { message; _ } -> Invalid_request message
  | A.Provider_error
      { provider = _; status; code; message; raw; retry_after_s = _ } -> (
      (* Never infer local Invalid_request from Provider_error shape. *)
      match raw with
      | Some raw_body -> (
          match Json.parse raw_body with
          | Ok json ->
              let payload = payload_of_json json in
              Provider_response
                {
                  status;
                  message =
                    (match payload.message with
                    | Some _ as value -> value
                    | None -> Some message);
                  type_ = payload.type_;
                  param = payload.param;
                  code =
                    (match payload.code with
                    | Some _ as value -> value
                    | None -> Option.map Json.string code);
                  raw = Some payload.raw;
                  full = Some payload.full;
                  raw_body = Some raw_body;
                }
          | Error _ ->
              Provider_response
                {
                  status;
                  message = Some message;
                  type_ = None;
                  param = None;
                  code = Option.map Json.string code;
                  raw = None;
                  full = None;
                  raw_body = Some raw_body;
                })
      | None ->
          Provider_response
            {
              status;
              message = Some message;
              type_ = None;
              param = None;
              code = Option.map Json.string code;
              raw = None;
              full = None;
              raw_body = None;
            })
  | A.Decode_error { message; raw; _ } -> Decode { message; raw_body = raw }
  | A.Invalid_tool { name; message } -> Invalid_tool { name; message }
  | A.Unsupported { feature; _ } -> Unsupported feature

let classification = function
  | Http _ -> "http_error"
  | Provider { payload = Some { code = Some (`String code); _ }; _ } -> code
  | Provider { payload = Some { type_ = Some type_; _ }; _ } -> type_
  | Provider _ -> "provider_error"
  | Unknown_response _ -> "unknown_response"
  | Provider_response { code = Some (`String code); _ } -> code
  | Provider_response { type_ = Some type_; _ } -> type_
  | Provider_response _ -> "provider_error"
  | Decode _ -> "decode_error"
  | Invalid_request _ -> "invalid_request"
  | Concurrent_use _ -> "concurrent_use"
  | Limit_exceeded _ -> "limit_exceeded"
  | Unsupported _ -> "unsupported"
  | Invalid_tool _ -> "invalid_tool"

let projected_code payload_code payload_type =
  match code_string payload_code with
  | Some _ as value -> value
  | None -> payload_type

let to_ai_error = function
  | Http error -> A.Eta_http_error error
  | Provider { status; headers; payload; raw_body } ->
      let payload_message =
        Option.bind payload (fun payload -> payload.message)
      in
      let payload_code = Option.bind payload (fun payload -> payload.code) in
      let payload_type = Option.bind payload (fun payload -> payload.type_) in
      A.Provider_error
        {
          provider = "openai";
          status = Some status;
          code = projected_code payload_code payload_type;
          message =
            Option.value payload_message
              ~default:("OpenAI HTTP " ^ string_of_int status);
          raw = Some raw_body;
          retry_after_s = A.retry_after_from_headers headers;
        }
  | Unknown_response { status; headers; raw_body; _ } ->
      A.Provider_error
        {
          provider = "openai";
          status = Some status;
          code = None;
          message = "Unrecognized OpenAI error response";
          raw = Some raw_body;
          retry_after_s = A.retry_after_from_headers headers;
        }
  | Provider_response
      { status; message; type_; code; raw = _; full = _; raw_body } ->
      A.Provider_error
        {
          provider = "openai";
          status;
          code = projected_code code type_;
          message =
            Option.value message ~default:"OpenAI provider error";
          raw = raw_body;
          retry_after_s = None;
        }
  | Decode { message; raw_body } ->
      A.Decode_error { provider = "openai"; message; raw = raw_body }
  | Invalid_request message ->
      A.Invalid_request { provider = "openai"; message }
  | Concurrent_use operation ->
      A.Invalid_request
        {
          provider = "openai";
          message = "concurrent OpenAI " ^ operation ^ " stream use";
        }
  | Limit_exceeded { kind; limit; actual } ->
      A.Invalid_request
        {
          provider = "openai";
          message =
            Printf.sprintf "%s exceeded limit %d (actual %d)" kind limit actual;
        }
  | Unsupported feature -> A.Unsupported { provider = "openai"; feature }
  | Invalid_tool { name; message } -> A.Invalid_tool { name; message }

let pp fmt = function
  | Http error -> Format.pp_print_string fmt (Eta_http.Error.to_string error)
  | Provider { status; payload; _ } ->
      let detail =
        match payload with
        | Some { code = Some code; _ } -> " (" ^ Json.compact code ^ ")"
        | Some { type_ = Some type_; _ } -> " (" ^ type_ ^ ")"
        | _ -> ""
      in
      Format.fprintf fmt "OpenAI HTTP %d%s" status detail
  | Unknown_response { status; _ } ->
      Format.fprintf fmt "OpenAI HTTP %d: unrecognized error response" status
  | Provider_response { status; code; type_; message; _ } ->
      let detail =
        match code with
        | Some code -> " (" ^ Json.compact code ^ ")"
        | None -> (
            match type_ with Some type_ -> " (" ^ type_ ^ ")" | None -> "")
      in
      Format.fprintf fmt "OpenAI provider error%s%s" detail
        (match status with
        | Some status -> " status=" ^ string_of_int status
        | None -> "");
      Option.iter (fun message -> Format.fprintf fmt ": %s" message) message
  | Decode { message; _ } ->
      Format.fprintf fmt "OpenAI decode error: %s" message
  | Invalid_request message ->
      Format.fprintf fmt "invalid OpenAI request: %s" message
  | Concurrent_use operation ->
      Format.fprintf fmt "concurrent OpenAI %s stream use" operation
  | Limit_exceeded { kind; limit; actual } ->
      Format.fprintf fmt "OpenAI %s exceeded limit %d (actual %d)" kind limit
        actual
  | Unsupported feature -> Format.fprintf fmt "openai unsupported %s" feature
  | Invalid_tool { name; message } ->
      Format.fprintf fmt "invalid OpenAI tool %s: %s" name message
