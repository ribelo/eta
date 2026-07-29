module A = Eta_ai
module Json = A.Json

type provider_payload = {
  message : string option;
  code : string option;
  type_ : string option;
  param : A.Json.t option;
  raw : A.Json.t;
}

type t =
  | Http of Eta_http.Error.t
  | Provider of {
      status : int;
      headers : A.headers;
      payload : provider_payload;
      raw_body : A.raw_json;
    }
  | Unknown_response of {
      status : int;
      headers : A.headers;
      raw_body : A.raw_json;
    }
  | Decode of {
      message : string;
      raw_body : A.raw_json option;
    }
  | Invalid_request of string

let payload_of_json json =
  let payload =
    match Json.object_member "error" json with Some error -> error | None -> json
  in
  {
    message = Json.scalar_string_member "message" payload;
    code = Json.scalar_string_member "code" payload;
    type_ = Json.scalar_string_member "type" payload;
    param = Json.member "param" payload;
    raw = payload;
  }

let decode ~status ~headers raw_body =
  match Json.parse raw_body with
  | Ok json ->
      Provider
        {
          status;
          headers;
          payload = payload_of_json json;
          raw_body;
        }
  | Error _ -> Unknown_response { status; headers; raw_body }

let to_ai_error = function
  | Http error -> A.Eta_http_error error
  | Provider { status; headers; payload; raw_body } ->
      A.Provider_error
        {
          provider = "xai";
          status = Some status;
          code = payload.code;
          message =
            Option.value payload.message ~default:("xAI HTTP " ^ string_of_int status);
          raw = Some raw_body;
          retry_after_s = A.retry_after_from_headers headers;
        }
  | Unknown_response { status; headers; raw_body } ->
      A.Provider_error
        {
          provider = "xai";
          status = Some status;
          code = None;
          message = "Unrecognized xAI error response";
          raw = Some raw_body;
          retry_after_s = A.retry_after_from_headers headers;
        }
  | Decode { message; raw_body } ->
      A.Decode_error { provider = "xai"; message; raw = raw_body }
  | Invalid_request message ->
      A.Provider_error
        {
          provider = "xai";
          status = None;
          code = Some "invalid_request";
          message;
          raw = None;
          retry_after_s = None;
        }

let pp fmt = function
  | Http error -> Format.pp_print_string fmt (Eta_http.Error.to_string error)
  | Provider { status; payload; _ } ->
      Format.fprintf fmt "xAI HTTP %d%s" status
        (match payload.code with None -> "" | Some code -> " (" ^ code ^ ")")
  | Unknown_response { status; _ } ->
      Format.fprintf fmt "xAI HTTP %d: unrecognized error response" status
  | Decode { message; _ } -> Format.fprintf fmt "xAI decode error: %s" message
  | Invalid_request message ->
      Format.fprintf fmt "invalid xAI request: %s" message
