let version = "v1.56.0"
let docs_url = "https://opentelemetry.io/docs/specs/semconv/http/http-spans/"

let http_request_method = "http.request.method"
let http_response_status_code = "http.response.status_code"
let http_request_resend_count = "http.request.resend_count"
let url_full = "url.full"
let server_address = "server.address"
let server_port = "server.port"
let network_protocol_name = "network.protocol.name"
let network_protocol_version = "network.protocol.version"
let error_type = "error.type"
let user_agent_original = "user_agent.original"

let metric_request_duration = "http.client.request.duration"
let metric_active_requests = "http.client.active_requests"
let metric_request_body_size = "http.client.request.body.size"
let metric_response_body_size = "http.client.response.body.size"
let metric_pool_active = "eta.http.client.pool.active"
let metric_pool_idle = "eta.http.client.pool.idle"

let attr key value = (key, value)
let int_attr key value = (key, string_of_int value)

let protocol_version = function
  | `H1 -> "1.1"
  | `H2 -> "2"

let server_of_url url =
  let after_scheme =
    match String.split_on_char '/' url with
    | scheme :: "" :: host :: _ when String.ends_with ~suffix:":" scheme -> host
    | _ -> url
  in
  match String.split_on_char ':' after_scheme with
  | host :: port :: _ -> (host, port)
  | host :: _ -> (host, if String.starts_with ~prefix:"https://" url then "443" else "80")
  | [] -> (url, "80")

let base_http_attrs ~method_ ~url ~protocol =
  let host, port = server_of_url url in
  [
    attr http_request_method method_;
    attr url_full url;
    attr server_address host;
    attr server_port port;
    attr network_protocol_name "http";
    attr network_protocol_version (protocol_version protocol);
    attr user_agent_original "eta-http/0.1";
  ]

let with_status status attrs = int_attr http_response_status_code status :: attrs
let with_error error attrs = attr error_type error :: attrs
let with_resend count attrs = int_attr http_request_resend_count count :: attrs
