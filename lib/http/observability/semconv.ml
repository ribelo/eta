module Client = Client
module Error = Error
module Redaction = Redaction
module Request = Request
module Response = Response
module Url = Url

let protocol_version = function
  | Client.H1 -> "1.1"
  | H2 -> "2"
  | Auto -> "unknown"

let protocol_name _ = "http"

let method_name method_ = Method.(method_ |> of_string |> to_string)

let request_attrs ?(emit_url_full = false) ~protocol request =
  let url_full =
    if emit_url_full then request.Request.uri else Redaction.uri request.uri
  in
  let base =
    [
      ("http.request.method", method_name request.Request.method_);
      ("url.full", url_full);
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

let redact_fragment uri =
  match String.index_opt uri '#' with
  | None -> uri
  | Some fragment_start ->
      let redacted = "#<redacted>" in
      let redacted_len = String.length redacted in
      let out = Bytes.create (fragment_start + redacted_len) in
      Bytes.blit_string uri 0 out 0 fragment_start;
      Bytes.blit_string redacted 0 out fragment_start redacted_len;
      Bytes.unsafe_to_string out

let redirect_attrs ?(emit_location_full = false) ~location () =
  let location =
    if emit_location_full then location else Redaction.uri location |> redact_fragment
  in
  [ ("http.response.header.location", location) ]
