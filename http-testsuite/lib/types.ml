(** Core types shared across the test suite. *)

type protocol = H1 | H2
type transport = Plain | TLS
type server_kind = Nginx | Caddy | Eta | Node | Go

type server_config = {
  kind : server_kind;
  protocol : protocol;
  transport : transport;
  port : int;
  temp_dir : string;
  cert_dir : string option;
}

type scenario_status =
  | Pass
  | Divergent
  | Fail
  | Skip of string

type normalized_result = {
  status : int;
  body_sha256 : string;
  body_length : int;
  headers_normalized : (string * string) list;
  trailers_normalized : (string * string) list;
}

type scenario_result = {
  name : string;
  server : server_kind;
  protocol : protocol;
  transport : transport;
  status : scenario_status;
  eta_result : normalized_result option;
  curl_result : normalized_result option;
  eta_error : string option;
  curl_error : string option;
  duration_ms : float;
}

type bench_iteration = {
  scenario : string;
  client : string;
  iteration : int;
  duration_ns : int64;
  minor_words : float;
  major_words : float;
  promoted_words : float;
  top_heap_words : int;
  rss_kb : int;
}

type adversarial_result = {
  name : string;
  passed : bool;
  skipped : string option;
  deadline_respected : bool;
  peak_rss_kb : int;
  error_variant : string option;
  eta_error : string option;
  duration_ms : float;
  fd_baseline : int;
  fd_after : int;
  minor_words_during : float;
  major_words_during : float;
}

type run_manifest = {
  run_id : string;
  git_sha : string;
  ocaml_version : string;
  nginx_version : string;
  caddy_version : string;
  curl_version : string;
  nghttp2_version : string;
  eta_http_sha : string;
  host : string;
  started_at : string;
}
