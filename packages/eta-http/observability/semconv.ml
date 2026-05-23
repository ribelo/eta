module Client = Eta_http_client.Client
module Error = Eta_http_error.Error
module Request = Eta_http_client.Request
module Response = Eta_http_client.Response
module Url = Eta_http_core.Url

let protocol_version = function
  | Client.H1 -> "1.1"
  | H2 -> "2"
  | Auto -> "unknown"

let protocol_name _ = "http"

let request_attrs ~protocol request =
  let base =
    [
      ("http.request.method", String.uppercase_ascii request.Request.method_);
      ("url.full", request.uri);
      ("network.protocol.name", protocol_name protocol);
      ("network.protocol.version", protocol_version protocol);
    ]
  in
  match Url.parse request.uri with
  | Error _ -> base
  | Ok url ->
      ("server.address", Url.host url)
      :: ("server.port", string_of_int (Url.effective_port url))
      :: base

let response_attrs response =
  [ ("http.response.status_code", string_of_int response.Response.status) ]

let error_attrs error =
  [
    ("error.type", Error.error_class error);
    ("eta_http.error.kind", Error.kind_name error.kind);
    ("eta_http.error.layer", Error.layer_to_string (Error.layer error));
    ( "eta_http.error.retryability",
      Error.retryability_to_string (Error.retryability error) );
  ]

let retry_attrs ~attempt =
  [ ("http.request.resend_count", string_of_int (max 0 (attempt - 1))) ]

let redirect_attrs ~location = [ ("http.response.header.location", location) ]
