(** JSON report serialization. *)

open Types

let yojson_of_string s = `String s
let yojson_of_int i = `Int i
let yojson_of_float f = `Float f
let yojson_of_int64 i = `Intlit (Int64.to_string i)
let yojson_of_bool b = `Bool b
let yojson_of_pair f g (a, b) = `List [ f a; g b ]
let yojson_of_list f xs = `List (List.map f xs)
let yojson_of_option f = function
  | None -> `Null
  | Some x -> f x

let yojson_of_protocol = function
  | H1 -> `String "h1"
  | H2 -> `String "h2"

let yojson_of_transport = function
  | Plain -> `String "plain"
  | TLS -> `String "tls"

let yojson_of_server_kind = function
  | Nginx -> `String "nginx"
  | Caddy -> `String "caddy"

let yojson_of_scenario_status = function
  | Pass -> `String "PASS"
  | Divergent -> `String "DIVERGENT"
  | Fail -> `String "FAIL"
  | Skip reason -> `Assoc [ ("status", `String "SKIP"); ("reason", `String reason) ]

let yojson_of_normalized_result (r : normalized_result) =
  `Assoc [
    ("status", yojson_of_int r.status);
    ("body_sha256", yojson_of_string r.body_sha256);
    ("body_length", yojson_of_int r.body_length);
    ("headers_normalized", yojson_of_list (yojson_of_pair yojson_of_string yojson_of_string) r.headers_normalized);
    ("trailers_normalized", yojson_of_list (yojson_of_pair yojson_of_string yojson_of_string) r.trailers_normalized);
  ]

let yojson_of_scenario_result (r : scenario_result) =
  `Assoc [
    ("name", yojson_of_string r.name);
    ("server", yojson_of_server_kind r.server);
    ("protocol", yojson_of_protocol r.protocol);
    ("transport", yojson_of_transport r.transport);
    ("status", yojson_of_scenario_status r.status);
    ("eta_result", yojson_of_option yojson_of_normalized_result r.eta_result);
    ("curl_result", yojson_of_option yojson_of_normalized_result r.curl_result);
    ("eta_error", yojson_of_option yojson_of_string r.eta_error);
    ("curl_error", yojson_of_option yojson_of_string r.curl_error);
    ("duration_ms", yojson_of_float r.duration_ms);
  ]

let yojson_of_bench_iteration (i : bench_iteration) =
  `Assoc [
    ("scenario", yojson_of_string i.scenario);
    ("client", yojson_of_string i.client);
    ("iteration", yojson_of_int i.iteration);
    ("duration_ns", yojson_of_int64 i.duration_ns);
    ("minor_words", yojson_of_float i.minor_words);
    ("major_words", yojson_of_float i.major_words);
    ("promoted_words", yojson_of_float i.promoted_words);
    ("top_heap_words", yojson_of_int i.top_heap_words);
    ("rss_kb", yojson_of_int i.rss_kb);
  ]

let yojson_of_adversarial_result (r : adversarial_result) =
  `Assoc [
    ("name", yojson_of_string r.name);
    ("passed", yojson_of_bool r.passed);
    ("deadline_respected", yojson_of_bool r.deadline_respected);
    ("peak_rss_kb", yojson_of_int r.peak_rss_kb);
    ("error_variant", yojson_of_option yojson_of_string r.error_variant);
    ("eta_error", yojson_of_option yojson_of_string r.eta_error);
    ("duration_ms", yojson_of_float r.duration_ms);
    ("fd_baseline", yojson_of_int r.fd_baseline);
    ("fd_after", yojson_of_int r.fd_after);
    ("minor_words_during", yojson_of_float r.minor_words_during);
    ("major_words_during", yojson_of_float r.major_words_during);
  ]

let yojson_of_run_manifest (m : run_manifest) =
  `Assoc [
    ("run_id", yojson_of_string m.run_id);
    ("git_sha", yojson_of_string m.git_sha);
    ("ocaml_version", yojson_of_string m.ocaml_version);
    ("nginx_version", yojson_of_string m.nginx_version);
    ("caddy_version", yojson_of_string m.caddy_version);
    ("curl_version", yojson_of_string m.curl_version);
    ("nghttp2_version", yojson_of_string m.nghttp2_version);
    ("eta_http_sha", yojson_of_string m.eta_http_sha);
    ("host", yojson_of_string m.host);
    ("started_at", yojson_of_string m.started_at);
  ]

let write_json ~path json =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Yojson.Safe.to_channel oc json)

let write_manifest ~path manifest =
  write_json ~path (yojson_of_run_manifest manifest)

let write_interop ~path results =
  write_json ~path (yojson_of_list yojson_of_scenario_result results)

let write_cve ~path results =
  write_json ~path (yojson_of_list yojson_of_adversarial_result results)

let write_bench ~path iterations =
  write_json ~path (yojson_of_list yojson_of_bench_iteration iterations)
