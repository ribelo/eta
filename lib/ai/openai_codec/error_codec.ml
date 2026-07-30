module A = Eta_ai
module Json = A.Json

type wire_error_payload = {
  message : string option;
  type_ : string option;
  param : A.Json.t option;
  code : A.Json.t option;
  (** Nested [error] object when present, otherwise the complete decoded body. *)
  raw : A.Json.t;
  (** Complete decoded response JSON. *)
  full : A.Json.t;
}

type wire_error =
  | Decodable of wire_error_payload
  | Undecodable of { raw_body : A.raw_json }

let error_object ?(nested_response_error = false) json =
  match Json.object_member "error" json with
  | Some _ as value -> value
  | None ->
      if nested_response_error then
        Option.bind
          (Json.object_member "response" json)
          (Json.object_member "error")
      else None

let wire_payload_of_json ?(nested_response_error = false) full =
  let error =
    match error_object ~nested_response_error full with
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

let decode_wire_error ?(nested_response_error = false) raw_body =
  match Json.parse raw_body with
  | Stdlib.Ok json ->
      Decodable (wire_payload_of_json ~nested_response_error json)
  | Stdlib.Error _ -> Undecodable { raw_body }

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

let provider_error_json ?status ?raw ?retry_after_s
    ?(nested_response_error = false) ~provider json =
  let payload = wire_payload_of_json ~nested_response_error json in
  let message =
    Option.value payload.message ~default:"provider returned an error"
  in
  let code =
    match code_string payload.code with
    | Some _ as value -> value
    | None -> payload.type_
  in
  A.Provider_error { provider; status; code; message; raw; retry_after_s }

let provider_error ?status ?retry_after_s ?(nested_response_error = false)
    ~provider raw =
  match decode_wire_error ~nested_response_error raw with
  | Decodable payload ->
      provider_error_json ?status ~raw ?retry_after_s ~nested_response_error
        ~provider payload.full
  | Undecodable { raw_body } ->
      A.Provider_error
        {
          provider;
          status;
          code = None;
          message = "provider returned an error";
          raw = Some raw_body;
          retry_after_s;
        }

let decode_error ?(nested_response_error = false) ~provider ~status ~headers raw
    =
  let retry_after_s = A.retry_after_from_headers headers in
  provider_error ~status ?retry_after_s ~nested_response_error ~provider raw
