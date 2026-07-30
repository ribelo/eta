module A = Eta_ai
module Json = A.Json

type provider_payload = A.Json.t

type t =
  | Http of Eta_http.Error.t
  | Provider of {
      provider : A.provider_name;
      response : provider_payload A.Provider.Error.http_response;
    }
  | Unknown_response of {
      provider : A.provider_name;
      response : unit A.Provider.Error.http_response;
    }
  | Provider_response of {
      provider : A.provider_name;
      status : int option;
      payload : A.Json.t option;
      raw_body : A.raw_json option;
      message : string option;
      code : string option;
    }
  | Decode of {
      provider : A.provider_name;
      message : string;
      raw_body : A.raw_json option;
    }
  | Invalid_request of {
      provider : A.provider_name;
      message : string;
    }
  | Unsupported of {
      provider : A.provider_name;
      feature : string;
    }
  | Invalid_tool of {
      name : string;
      message : string;
    }

let default_provider = "openai-compatible"

let wire_code_and_message json =
  let error =
    match Json.object_member "error" json with
    | Some error -> error
    | None -> json
  in
  let message =
    Json.scalar_string_member "message" error
    |> Option.value ~default:"provider returned an error"
  in
  let code =
    match Json.scalar_string_member "code" error with
    | Some _ as value -> value
    | None -> Json.scalar_string_member "type" error
  in
  (code, message)

let decode ~provider ~status ~headers raw_body =
  match Json.parse raw_body with
  | Ok json ->
      Provider
        {
          provider;
          response = { status; headers; payload = Some json; raw_body };
        }
  | Error _ ->
      Unknown_response
        {
          provider;
          response = { status; headers; payload = None; raw_body };
        }

let of_wire_payload ~provider ?status ?raw_body
    (payload : Eta_ai_openai_codec.wire_error_payload) =
  Provider_response
    {
      provider;
      status;
      payload = Some payload.full;
      raw_body;
      message = payload.message;
      code =
        (match payload.code with
        | Some (`String value) -> Some value
        | Some other -> Some (Json.compact other)
        | None -> payload.type_);
    }

let of_codec_failure ~provider = function
  | Eta_ai_openai_codec.Invalid_request message ->
      Invalid_request { provider; message }
  | Eta_ai_openai_codec.Unsupported feature -> Unsupported { provider; feature }
  | Eta_ai_openai_codec.Invalid_tool { name; message } ->
      Invalid_tool { name; message }
  | Eta_ai_openai_codec.Decode { message; raw_body } ->
      Decode { provider; message; raw_body }

let of_ai_error ?(provider = default_provider) = function
  | A.Eta_http_error error -> Http error
  | A.Invalid_request { provider = _; message } ->
      Invalid_request
        {
          provider;
          message;
        }
  | A.Provider_error
      { provider = _; message; raw; status; code; retry_after_s = _ } ->
      (* Never infer local Invalid_request from neutral Provider_error shape. *)
      Provider_response
        {
          provider;
          status;
          payload =
            (match raw with
            | Some raw_body -> (
                match Json.parse raw_body with
                | Ok json -> Some json
                | Error _ -> None)
            | None -> None);
          raw_body = raw;
          message = Some message;
          code;
        }
  | A.Decode_error { provider = _; message; raw } ->
      Decode
        {
          provider;
          message;
          raw_body = raw;
        }
  | A.Invalid_tool { name; message } -> Invalid_tool { name; message }
  | A.Unsupported { provider = _; feature } ->
      Unsupported
        {
          provider;
          feature;
        }

let classification = function
  | Http _ -> "http_error"
  | Provider { response = { payload = Some json; _ }; _ } -> (
      match wire_code_and_message json with
      | Some code, _ -> code
      | None, _ -> "provider_error")
  | Provider _ -> "provider_error"
  | Unknown_response _ -> "unknown_response"
  | Provider_response { code = Some code; _ } -> code
  | Provider_response _ -> "provider_error"
  | Decode _ -> "decode_error"
  | Invalid_request _ -> "invalid_request"
  | Unsupported _ -> "unsupported"
  | Invalid_tool _ -> "invalid_tool"

let to_ai_error = function
  | Http error -> A.Eta_http_error error
  | Provider { provider; response = { status; headers; payload; raw_body } } ->
      let code, message =
        match payload with
        | Some json -> wire_code_and_message json
        | None -> (None, "provider returned an error")
      in
      A.Provider_error
        {
          provider;
          status = Some status;
          code;
          message;
          raw = Some raw_body;
          retry_after_s = A.retry_after_from_headers headers;
        }
  | Unknown_response { provider; response = { status; headers; raw_body; _ } }
    ->
      A.Provider_error
        {
          provider;
          status = Some status;
          code = None;
          message = "Unrecognized provider error response";
          raw = Some raw_body;
          retry_after_s = A.retry_after_from_headers headers;
        }
  | Provider_response { provider; status; payload = _; raw_body; message; code }
    ->
      A.Provider_error
        {
          provider;
          status;
          code;
          message = Option.value message ~default:"provider returned an error";
          raw = raw_body;
          retry_after_s = None;
        }
  | Decode { provider; message; raw_body } ->
      A.Decode_error { provider; message; raw = raw_body }
  | Invalid_request { provider; message } ->
      A.Invalid_request { provider; message }
  | Unsupported { provider; feature } -> A.Unsupported { provider; feature }
  | Invalid_tool { name; message } -> A.Invalid_tool { name; message }

let pp fmt = function
  | Http error -> Format.pp_print_string fmt (Eta_http.Error.to_string error)
  | Provider { provider; response = { status; payload; _ } } ->
      let detail =
        match payload with
        | Some json -> (
            match wire_code_and_message json with
            | Some code, _ -> " (" ^ code ^ ")"
            | None, _ -> "")
        | None -> ""
      in
      Format.fprintf fmt "%s HTTP %d%s" provider status detail
  | Unknown_response { provider; response = { status; _ } } ->
      Format.fprintf fmt "%s HTTP %d: unrecognized error response" provider
        status
  | Provider_response { provider; status; code; message; _ } ->
      Format.fprintf fmt "%s provider error%s%s" provider
        (match code with Some code -> " (" ^ code ^ ")" | None -> "")
        (match status with
        | Some status -> " status=" ^ string_of_int status
        | None -> "");
      Option.iter (fun message -> Format.fprintf fmt ": %s" message) message
  | Decode { provider; message; _ } ->
      Format.fprintf fmt "%s decode error: %s" provider message
  | Invalid_request { provider; message } ->
      Format.fprintf fmt "invalid %s request: %s" provider message
  | Unsupported { provider; feature } ->
      Format.fprintf fmt "%s unsupported %s" provider feature
  | Invalid_tool { name; message } ->
      Format.fprintf fmt "invalid tool %s: %s" name message
