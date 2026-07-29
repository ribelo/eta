module Url = Eta_http.Core.Url

type inference = {
  base_url : string;
}

type management = {
  base_url : string;
}

let normalized value =
  if String.length value > 0 && value.[String.length value - 1] = '/' then
    String.sub value 0 (String.length value - 1)
  else value

let parse role value =
  let base_url = normalized value in
  match Url.parse base_url with
  | Ok _ -> Ok base_url
  | Error error ->
      Error
        (Xai_error.Invalid_request
           (Printf.sprintf "invalid xAI %s endpoint: %s" role
              (Url.parse_error_to_string error)))

let inference value : (inference, Xai_error.t) result =
  parse "inference" value
  |> Result.map (fun base_url -> ({ base_url } : inference))

let management value : (management, Xai_error.t) result =
  parse "management" value
  |> Result.map (fun base_url -> ({ base_url } : management))

let default_inference : inference =
  {
    base_url = "https://api.x.ai";
  }

let default_management : management =
  {
    base_url = "https://management-api.x.ai";
  }

let inference_base_url (value : inference) = value.base_url
let management_base_url (value : management) = value.base_url
