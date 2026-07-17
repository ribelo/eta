module A = Eta_ai
module Json = A.Json

let error_object ?(nested_response_error = false) json =
  match Json.object_member "error" json with
  | Some _ as value -> value
  | None ->
      if nested_response_error then
        Option.bind
          (Json.object_member "response" json)
          (Json.object_member "error")
      else None

let provider_error_json ?status ?raw ?retry_after_s
    ?(nested_response_error = false) ~provider json =
  let error = error_object ~nested_response_error json in
  let message =
    Option.bind error (Json.string_member "message")
    |> Option.value ~default:"provider returned an error"
  in
  let code =
    match Option.bind error (Json.scalar_string_member "code") with
    | Some _ as value -> value
    | None -> Option.bind error (Json.string_member "type")
  in
  A.Provider_error
    { provider; status; code; message; raw; retry_after_s }

let provider_error ?status ?retry_after_s ?(nested_response_error = false)
    ~provider raw =
  match Json.parse raw with
  | Stdlib.Ok json ->
      provider_error_json ?status ~raw ?retry_after_s ~nested_response_error
        ~provider json
  | Stdlib.Error _ ->
      A.Provider_error
        {
          provider;
          status;
          code = None;
          message = "provider returned an error";
          raw = Some raw;
          retry_after_s;
        }

let decode_error ?(nested_response_error = false) ~provider ~status ~headers raw
    =
  let retry_after_s = A.retry_after_from_headers headers in
  provider_error ~status ?retry_after_s ~nested_response_error ~provider raw
