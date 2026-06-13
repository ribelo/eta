(** Interop scenario definitions and runner framework. *)

open Types
open Eio.Std

let make_request ~method_ ~url ~headers ?body () =
  let headers =
    match Eta_http.Core.Header.of_list headers with
    | Ok h -> h
    | Error _ -> Eta_http.Core.Header.empty
  in
  let body =
    match body with
    | None -> Eta_http.Request.Empty
    | Some b -> Eta_http.Request.Fixed [ Bytes.of_string b ]
  in
  Eta_http.Request.make ~headers ~body method_ url

let pp_eta_error fmt (error : Eta_http.Error.t) =
  Format.fprintf fmt "%a" Eta_http.Error.pp error;
  match error.kind with
  | Connection_protocol_violation { kind; message } ->
      Format.fprintf fmt " detail=%s:%s" kind message
  | Decode_error { codec; message } ->
      Format.fprintf fmt " detail=%s:%s" codec message
  | Body_too_large { limit; length } ->
      Format.fprintf fmt " detail=body_too_large:%d>%d" length limit
  | _ -> ()

let normalize_header_list headers =
  headers
  |> List.map (fun (k, v) -> (String.lowercase_ascii k, String.trim v))
  |> List.filter (fun (k, _) ->
         k <> "date" && k <> "server" && k <> "via" && k <> "set-cookie"
         && k <> "connection" && k <> "transfer-encoding")
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let run_eta ~rt ~client ~request =
  let start = Util.now_ms () in
  let result =
    Eta_http.request client request
    |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
           Util.body_to_string response.body
           |> Eta.Effect.bind (fun body ->
                  response.trailers ()
                  |> Eta.Effect.map (fun trailers ->
                         let headers_normalized =
                           Eta_http.Core.Header.to_list response.headers
                           |> normalize_header_list
                         in
                         let trailers_normalized =
                           Eta_http.Core.Header.to_list trailers
                           |> normalize_header_list
                         in
                         ( Ok
                             {
                               status = response.status;
                               body_sha256 = Util.sha256_of_string body;
                               body_length = String.length body;
                               headers_normalized;
                               trailers_normalized;
                             },
                           None ))))
    |> Eta.Runtime.run rt
  in
  let duration_ms = Util.now_ms () -. start in
  match result with
  | Eta.Exit.Ok (res, _) -> res, duration_ms
  | Eta.Exit.Error cause ->
      let msg = Format.asprintf "%a" (Eta.Cause.pp pp_eta_error) cause in
      Error msg, duration_ms

let build_url ~transport ~port ~path =
  let scheme = match transport with Plain -> "http" | TLS -> "https" in
  Printf.sprintf "%s://127.0.0.1:%d%s" scheme port path

let server_kind_slug = function
  | Nginx -> "nginx"
  | Caddy -> "caddy"
  | Eta -> "eta"
  | Node -> "node"
  | Go -> "go"
let protocol_slug = function H1 -> "h1" | H2 -> "h2"
let transport_slug = function Plain -> "plain" | TLS -> "tls"

let config_slug (kind, protocol, transport) =
  Printf.sprintf "%s:%s:%s" (server_kind_slug kind) (protocol_slug protocol)
    (transport_slug transport)

let split_csv raw =
  raw |> String.split_on_char ',' |> List.map String.trim
  |> List.filter (fun value -> not (String.equal value ""))

let filter_configs configs =
  match Sys.getenv_opt "ETA_HTTP_TESTSUITE_CONFIGS" with
  | None | Some "" -> configs
  | Some raw ->
      let allowed = split_csv raw in
      List.filter (fun config -> List.mem (config_slug config) allowed) configs

let make_client ~env ~sw ~protocol ~transport ~cert_dir =
  let max_response_body_bytes = 128 * 1024 * 1024 in
  let ca_file =
    match transport with Plain -> None | TLS -> Some (Certs.ca_path cert_dir)
  in
  match protocol with
  | H1 ->
      Eta_http_eio.Client.make_h1 ~sw ~net:(Eio.Stdenv.net env)
        ~max_response_body_bytes ?ca_file ()
  | H2 ->
      Eta_http_eio.Client.make ~sw ~net:(Eio.Stdenv.net env)
        ~max_response_body_bytes ?ca_file ()

type scenario = {
  name : string;
  method_ : string;
  path : string;
  headers : (string * string) list;
  body : string option;
  expected_status : int option;
  h2_only : bool;
  insecure : bool;
  skip : string option;
}

let filter_scenarios (scenarios : scenario list) =
  match Sys.getenv_opt "ETA_HTTP_TESTSUITE_SCENARIOS" with
  | None | Some "" -> scenarios
  | Some raw ->
      let allowed = split_csv raw in
      List.filter (fun scenario -> List.mem scenario.name allowed) scenarios

let default_scenarios = [
  (* Basic methods *)
  { name = "get_ok"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "head_ok"; method_ = "HEAD"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "post_echo"; method_ = "POST"; path = "/echo"; headers = [("Content-Type", "text/plain")];
    body = Some "hello world"; expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "expect_100_continue_upload"; method_ = "POST"; path = "/echo";
    headers = [("Expect", "100-continue"); ("Content-Type", "text/plain")];
    body = Some "continue body"; expected_status = Some 200; h2_only = false;
    insecure = false; skip = None };
  { name = "put_echo"; method_ = "PUT"; path = "/echo"; headers = [("Content-Type", "text/plain")];
    body = Some "put body"; expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "delete_ok"; method_ = "DELETE"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "patch_echo"; method_ = "PATCH"; path = "/echo"; headers = [("Content-Type", "text/plain")];
    body = Some "patch body"; expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "options_ok"; method_ = "OPTIONS"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  (* Body sizes *)
  { name = "zero_byte_body"; method_ = "POST"; path = "/echo"; headers = [("Content-Type", "text/plain")];
    body = Some ""; expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "small_body_1k"; method_ = "POST"; path = "/echo"; headers = [("Content-Type", "text/plain")];
    body = Some (String.make 1024 'x'); expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "large_body_1m"; method_ = "POST"; path = "/echo"; headers = [("Content-Type", "text/plain")];
    body = Some (String.make (1024 * 1024) 'x'); expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  (* Static files *)
  { name = "static_empty"; method_ = "GET"; path = "/static/empty.txt"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "static_1k"; method_ = "GET"; path = "/static/1k.bin"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "static_1m"; method_ = "GET"; path = "/static/1m.bin"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  { name = "static_100m"; method_ = "GET"; path = "/static/100m.bin"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  (* Status coverage *)
  { name = "status_204"; method_ = "GET"; path = "/status204"; headers = []; body = None;
    expected_status = Some 204; h2_only = false; insecure = false; skip = None };
  { name = "status_206"; method_ = "GET"; path = "/status206"; headers = []; body = None;
    expected_status = Some 206; h2_only = false; insecure = false; skip = None };
  { name = "status_301"; method_ = "GET"; path = "/redirect301"; headers = []; body = None;
    expected_status = Some 301; h2_only = false; insecure = false; skip = None };
  { name = "status_302"; method_ = "GET"; path = "/redirect302"; headers = []; body = None;
    expected_status = Some 302; h2_only = false; insecure = false; skip = None };
  { name = "status_307"; method_ = "GET"; path = "/redirect307"; headers = []; body = None;
    expected_status = Some 307; h2_only = false; insecure = false; skip = None };
  { name = "status_308"; method_ = "GET"; path = "/redirect308"; headers = []; body = None;
    expected_status = Some 308; h2_only = false; insecure = false; skip = None };
  { name = "status_400"; method_ = "GET"; path = "/status400"; headers = []; body = None;
    expected_status = Some 400; h2_only = false; insecure = false; skip = None };
  { name = "status_401"; method_ = "GET"; path = "/status401"; headers = []; body = None;
    expected_status = Some 401; h2_only = false; insecure = false; skip = None };
  { name = "status_404"; method_ = "GET"; path = "/nonexistent"; headers = []; body = None;
    expected_status = Some 404; h2_only = false; insecure = false; skip = None };
  { name = "status_413"; method_ = "GET"; path = "/status413"; headers = []; body = None;
    expected_status = Some 413; h2_only = false; insecure = false; skip = None };
  { name = "status_429"; method_ = "GET"; path = "/status429"; headers = []; body = None;
    expected_status = Some 429; h2_only = false; insecure = false; skip = None };
  { name = "status_500"; method_ = "GET"; path = "/status500"; headers = []; body = None;
    expected_status = Some 500; h2_only = false; insecure = false; skip = None };
  { name = "status_502"; method_ = "GET"; path = "/status502"; headers = []; body = None;
    expected_status = Some 502; h2_only = false; insecure = false; skip = None };
  { name = "status_503"; method_ = "GET"; path = "/status503"; headers = []; body = None;
    expected_status = Some 503; h2_only = false; insecure = false; skip = None };
  { name = "status_504"; method_ = "GET"; path = "/status504"; headers = []; body = None;
    expected_status = Some 504; h2_only = false; insecure = false; skip = None };
  (* Headers *)
  { name = "custom_headers"; method_ = "GET"; path = "/healthz";
    headers = [("X-Custom", "value"); ("X-Another", "val2")]; body = None;
    expected_status = Some 200; h2_only = false; insecure = false; skip = None };
  (* Trailers — h2 only because h1 trailers require TE: trailers and are less uniformly supported *)
  { name = "response_trailers"; method_ = "GET"; path = "/trailer"; headers = []; body = None;
    expected_status = Some 200; h2_only = true; insecure = false; skip = None };
  (* Deliberately skipped cells with notes *)
  { name = "status_100_continue"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 100; h2_only = false; insecure = false;
    skip = Some "100 Continue is covered by expect_100_continue_upload; informational-only status has no final response body" };
  { name = "status_103_early_hints"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 103; h2_only = false; insecure = false;
    skip = Some "103 Early Hints not exposed by eta-http public API in v1" };
  { name = "chunked_post_explicit"; method_ = "POST"; path = "/echo"; headers = [];
    body = None; expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "chunked framing requires Eta_stream body type; not exercised in v1 scenario list" };
  { name = "max_redirect_cap"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "eta-http does not auto-follow redirects; cap testing belongs in redirect-policy unit tests" };
  { name = "cookie_scope_redirect"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "cookie jar and redirect scoping not implemented in eta-http v1" };
  { name = "compression_gzip"; method_ = "GET"; path = "/"; headers = [("Accept-Encoding", "gzip")];
    body = None; expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "compression endpoint not configured in v1 server templates" };
  { name = "compression_deflate"; method_ = "GET"; path = "/"; headers = [("Accept-Encoding", "deflate")];
    body = None; expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "compression endpoint not configured in v1 server templates" };
  { name = "keep_alive_reuse_h1"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "connection reuse metric requires explicit pool instrumentation; bench covers throughput instead" };
  { name = "h2_multiplex_100_streams"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = true; insecure = false;
    skip = Some "100 concurrent streams scenario is a bench fixture, not an interop correctness test" };
  { name = "goaway_mid_flight"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 200; h2_only = true; insecure = false;
    skip = Some "GOAWAY mid-flight requires adversarial server fixture; covered in @cve-regress instead" };
  { name = "rst_stream_mid_flight"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 200; h2_only = true; insecure = false;
    skip = Some "RST_STREAM mid-flight requires adversarial server fixture; covered in @cve-regress instead" };
  { name = "server_close_mid_body"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "mid-body close requires dynamic server kill; covered in research probes, not v1 interop matrix" };
  { name = "tls_alpn_h2_negotiation"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "ALPN h2 vs h1 is implicitly exercised by every TLS+h2 cell; explicit ALPN test not needed for v1" };
  { name = "tls_resumption_1rtt"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "TLS resumption is covered by OpenSSL unit tests; interop runner does not keep a client session across requests" };
  { name = "tls_sni_mismatch"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "strict SNI mismatch is covered in TLS unit tests; interop needs a hostname-routed TLS fixture" };
  { name = "slow_body_timeout"; method_ = "GET"; path = "/"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "slow body timeout is an adversarial fixture; covered in @cve-regress" };
  { name = "idle_keep_alive_eviction"; method_ = "GET"; path = "/healthz"; headers = []; body = None;
    expected_status = Some 200; h2_only = false; insecure = false;
    skip = Some "idle eviction requires server-side timeout tuning and long waits; bench covers latency instead" };
]

let write_scenario_output ~results_dir ~name ~server_config eta_res curl_res =
  let { kind; protocol; transport; _ } = server_config in
  let dir = Filename.concat results_dir
      (Printf.sprintf "%s_%s_%s_%s"
         name
         (server_kind_slug kind)
         (match protocol with H1 -> "h1" | H2 -> "h2")
         (match transport with Plain -> "plain" | TLS -> "tls")) in
  Util.mkdir_p dir;
  (match eta_res with
   | Ok r -> Json.write_json ~path:(Filename.concat dir "eta.json") (Json.yojson_of_normalized_result r)
   | Error e -> Util.write_file (Filename.concat dir "eta_error.txt") e);
  (match curl_res with
   | Ok r -> Json.write_json ~path:(Filename.concat dir "curl.json") (Json.yojson_of_normalized_result r)
   | Error e -> Util.write_file (Filename.concat dir "curl_error.txt") e);
  (match eta_res, curl_res with
   | Ok e, Ok c when not (Curl.result_equal e c) ->
       let diff = Printf.sprintf "eta status=%d curl status=%d\neta sha=%s curl sha=%s\neta len=%d curl len=%d\n"
           e.status c.status e.body_sha256 c.body_sha256 e.body_length c.body_length in
       Util.write_file (Filename.concat dir "diff.txt") diff
   | _ -> ())

let write_eta_server_output ~results_dir ~name ~server_config expected curl_res =
  let { kind; protocol; transport; _ } = server_config in
  let dir =
    Filename.concat results_dir
      (Printf.sprintf "%s_%s_%s_%s" name
         (server_kind_slug kind)
         (match protocol with H1 -> "h1" | H2 -> "h2")
         (match transport with Plain -> "plain" | TLS -> "tls"))
  in
  Util.mkdir_p dir;
  (match expected with
  | Ok r ->
      Json.write_json ~path:(Filename.concat dir "expected.json")
        (Json.yojson_of_normalized_result r)
  | Error e -> Util.write_file (Filename.concat dir "expected_error.txt") e);
  (match curl_res with
  | Ok r ->
      Json.write_json ~path:(Filename.concat dir "curl.json")
        (Json.yojson_of_normalized_result r)
  | Error e -> Util.write_file (Filename.concat dir "curl_error.txt") e);
  match (expected, curl_res) with
  | Ok e, Ok c ->
      let diff =
        Printf.sprintf
          "expected status=%d curl status=%d\nexpected sha=%s curl sha=%s\nexpected len=%d curl len=%d\nexpected trailers=%d curl trailers=%d\n"
          e.status c.status e.body_sha256 c.body_sha256 e.body_length
          c.body_length (List.length e.trailers_normalized)
          (List.length c.trailers_normalized)
      in
      Util.write_file (Filename.concat dir "diff.txt") diff
  | _ -> ()

let normalized_string ?(headers = []) ?(trailers = []) ~status body =
  {
    status;
    body_sha256 = Util.sha256_of_string body;
    body_length = String.length body;
    headers_normalized = headers;
    trailers_normalized = trailers;
  }

let normalized_file ~status path =
  {
    status;
    body_sha256 = Util.sha256_of_file path;
    body_length = (Unix.stat path).st_size;
    headers_normalized = [];
    trailers_normalized = [];
  }

let eta_expected_result ~temp_dir scenario =
  let status = Option.value ~default:200 scenario.expected_status in
  if String.equal scenario.method_ "HEAD" || status = 204 then
    Ok (normalized_string ~status "")
  else
    match scenario.path with
    | "/healthz" -> Ok (normalized_string ~status "ok\n")
    | "/echo" | "/reflect" ->
        Ok (normalized_string ~status (Option.value ~default:"" scenario.body))
    | "/trailer" ->
        Ok
          (normalized_string ~status "body-with-trailer"
             ~headers:[ ("trailer", "X-Trailer") ])
    | "/status206" -> Ok (normalized_string ~status "partial")
    | "/status400" | "/status401" | "/status413" | "/status429"
    | "/status500" | "/status502" | "/status503" | "/status504"
    | "/redirect301" | "/redirect302" | "/redirect307" | "/redirect308"
    | "/nonexistent" ->
        Ok (normalized_string ~status "")
    | path when String.starts_with ~prefix:"/static/" path ->
        let prefix = "/static/" in
        let name =
          String.sub path (String.length prefix)
            (String.length path - String.length prefix)
        in
        let file = Filename.concat temp_dir name in
        if Sys.file_exists file then Ok (normalized_file ~status file)
        else Error ("missing static fixture: " ^ file)
    | path -> Error ("no Eta expected response for scenario path: " ^ path)

let eta_server_result_equal (expected : normalized_result)
    (actual : normalized_result) =
  expected.status = actual.status
  && expected.body_sha256 = actual.body_sha256
  && expected.body_length = actual.body_length
  && List.for_all
       (fun header -> List.mem header actual.headers_normalized)
       expected.headers_normalized
  &&
  match expected.trailers_normalized with
  | [] -> true
  | trailers ->
      List.for_all
        (fun trailer -> List.mem trailer actual.trailers_normalized)
        trailers

let eta_server_mismatch (expected : normalized_result) (actual : normalized_result) =
  Printf.sprintf
    "expected status=%d sha=%s len=%d trailers=%d; curl status=%d sha=%s len=%d trailers=%d"
    expected.status expected.body_sha256 expected.body_length
    (List.length expected.trailers_normalized)
    actual.status actual.body_sha256 actual.body_length
    (List.length actual.trailers_normalized)

let scenario_body_path ~temp_dir scenario =
  match scenario.body with
  | Some b ->
      let p = Filename.concat temp_dir "req_body" in
      Util.write_file p b;
      Some p
  | None -> None

let run_curl ~env ~server_config scenario =
  let { kind; protocol; transport; port; temp_dir; _ } = server_config in
  let url = build_url ~transport ~port ~path:scenario.path in
  let body_path = scenario_body_path ~temp_dir scenario in
  let run () =
    Curl.run ~url ~method_:scenario.method_ ~headers:scenario.headers
      ~body_path ~insecure:(transport = TLS || scenario.insecure)
      ~http2:(protocol = H2)
      ~http2_prior_knowledge:(kind = Eta && protocol = H2 && transport = Plain)
      ~tmp_dir:temp_dir
  in
  match kind with
  | Eta -> Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) run
  | Nginx | Caddy | Node | Go -> run ()

let skipped_result ~kind ~protocol ~transport ~name reason =
  [
    {
      name;
      server = kind;
      protocol;
      transport;
      status = Skip reason;
      eta_result = None;
      curl_result = None;
      eta_error = None;
      curl_error = None;
      duration_ms = 0.0;
    };
  ]

let eta_server_skip_reason ~kind:_ ~protocol:_ _scenario = None

let run_external_server_scenario ~env ~sw ~rt ~server_config ~results_dir
    scenario =
  let { kind; protocol; transport; port; temp_dir; cert_dir } = server_config in
  let client =
    make_client ~env ~sw ~protocol ~transport
      ~cert_dir:(Option.value ~default:"" cert_dir)
  in
  let url = build_url ~transport ~port ~path:scenario.path in
  let request =
    make_request ~method_:scenario.method_ ~url ~headers:scenario.headers
      ?body:scenario.body ()
  in
  let eta_res, duration_ms = run_eta ~rt ~client ~request in
  ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
  let curl_res = run_curl ~env ~server_config scenario in
  let status =
    match (eta_res, curl_res) with
    | Ok e, Ok c -> if Curl.result_equal e c then Pass else Divergent
    | Error _, _ | _, Error _ -> Fail
  in
  if status = Divergent || status = Fail then
    write_scenario_output ~results_dir ~name:scenario.name ~server_config
      eta_res curl_res;
  [
    {
      name = scenario.name;
      server = kind;
      protocol;
      transport;
      status;
      eta_result = (match eta_res with Ok r -> Some r | Error _ -> None);
      curl_result = (match curl_res with Ok r -> Some r | Error _ -> None);
      eta_error = (match eta_res with Error e -> Some e | Ok _ -> None);
      curl_error = (match curl_res with Error e -> Some e | Ok _ -> None);
      duration_ms;
    };
  ]

let run_eta_server_scenario ~env ~server_config ~results_dir scenario =
  let { kind; protocol; transport; temp_dir; _ } = server_config in
  let start = Util.now_ms () in
  let expected = eta_expected_result ~temp_dir scenario in
  let curl_res = run_curl ~env ~server_config scenario in
  let duration_ms = Util.now_ms () -. start in
  let status, eta_error, curl_error =
    match (expected, curl_res) with
    | Ok expected, Ok actual ->
        if eta_server_result_equal expected actual then (Pass, None, None)
        else (Fail, None, Some (eta_server_mismatch expected actual))
    | Error error, _ -> (Fail, Some error, None)
    | _, Error error -> (Fail, None, Some error)
  in
  if status = Fail then
    write_eta_server_output ~results_dir ~name:scenario.name ~server_config
      expected curl_res;
  [
    {
      name = scenario.name;
      server = kind;
      protocol;
      transport;
      status;
      eta_result = None;
      curl_result = (match curl_res with Ok r -> Some r | Error _ -> None);
      eta_error;
      curl_error;
      duration_ms;
    };
  ]

let run_one_scenario ~env ~sw ~rt ~server_config ~results_dir scenario =
  let { kind; protocol; transport; _ } = server_config in
  match scenario.skip with
  | Some reason ->
      skipped_result ~kind ~protocol ~transport ~name:scenario.name reason
  | None ->
      if scenario.h2_only && protocol = H1 then
        skipped_result ~kind ~protocol ~transport ~name:scenario.name
          "h2-only scenario on h1"
      else
        match eta_server_skip_reason ~kind ~protocol scenario with
        | Some reason ->
            skipped_result ~kind ~protocol ~transport ~name:scenario.name
              reason
        | None -> (
            match kind with
            | Eta ->
                run_eta_server_scenario ~env ~server_config ~results_dir scenario
            | Nginx | Caddy ->
                run_external_server_scenario ~env ~sw ~rt ~server_config
                  ~results_dir scenario
            | Node | Go ->
                skipped_result ~kind ~protocol ~transport ~name:scenario.name
                  "server kind is only used by server-load benchmarks")

let run_all ~env ~results_dir ~scenarios =
  let scenarios = filter_scenarios scenarios in
  let configs =
    filter_configs
      [
        (Nginx, H1, Plain);
        (Nginx, H1, TLS);
        (Nginx, H2, TLS);
        (Caddy, H1, Plain);
        (Caddy, H1, TLS);
        (Caddy, H2, TLS);
        (Eta, H1, Plain);
        (Eta, H2, Plain);
        (Eta, H1, TLS);
        (Eta, H2, TLS);
      ]
  in
  let all_results = ref [] in
  let record_start_failure ~kind ~protocol ~transport error =
    Printf.eprintf "Server start failed: %s\n%!" error;
    List.iter
      (fun scenario ->
        all_results :=
          {
            name = scenario.name;
            server = kind;
            protocol;
            transport;
            status = Fail;
            eta_result = None;
            curl_result = None;
            eta_error = Some ("server start failed: " ^ error);
            curl_error = None;
            duration_ms = 0.0;
          }
          :: !all_results)
      scenarios
  in
  let run_scenarios ~sw server_config =
    let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    List.iter
      (fun scenario ->
        let results =
          run_one_scenario ~env ~sw ~rt ~server_config ~results_dir scenario
        in
        all_results := results @ !all_results)
      scenarios
  in
  List.iter (fun (kind, protocol, transport) ->
      let temp_dir = Filename.concat results_dir
          (Printf.sprintf "server_%s_%s_%s"
             (server_kind_slug kind)
             (match protocol with H1 -> "h1" | H2 -> "h2")
             (match transport with Plain -> "plain" | TLS -> "tls")) in
      Util.mkdir_p temp_dir;
      let port = Util.random_port () in
      let cert_dir =
        match transport with
        | TLS ->
            (match Certs.prepare ~temp_dir with
             | Ok d -> Some d
             | Error e -> failwith ("cert generation failed: " ^ e))
        | Plain -> None
      in
      ignore (Fixtures.generate ~dir:temp_dir);
      let server_config = { kind; protocol; transport; port; temp_dir; cert_dir } in
      match kind with
      | Nginx | Caddy -> (
          let pid_path =
            match kind with
            | Nginx ->
                Nginx.start ~port ~temp_dir
                  ~cert_dir:(Option.value ~default:"" cert_dir) ~protocol
                  ~transport
            | Caddy ->
                Caddy.start ~port ~temp_dir
                  ~cert_dir:(Option.value ~default:"" cert_dir) ~protocol
                  ~transport
            | Eta | Node | Go -> assert false
          in
          match pid_path with
          | Error e -> record_start_failure ~kind ~protocol ~transport e
          | Ok pid_path ->
              Fun.protect
                ~finally:(fun () ->
                  match kind with
                  | Nginx -> ignore (Nginx.stop pid_path)
                  | Caddy -> ignore (Caddy.stop pid_path)
                  | Eta | Node | Go -> ())
                (fun () -> Eio.Switch.run (fun sw -> run_scenarios ~sw server_config)))
      | Eta ->
          Eio.Switch.run (fun sw ->
              match
                Eta_server.start ~sw ~env ~port ~temp_dir ?cert_dir ~protocol
                  ~transport ()
              with
              | Error e -> record_start_failure ~kind ~protocol ~transport e
              | Ok server ->
                  Fun.protect
                    ~finally:(fun () -> ignore (Eta_server.stop server))
                    (fun () -> run_scenarios ~sw server_config))
      | Node | Go ->
          record_start_failure ~kind ~protocol ~transport
            "server kind is only used by server-load benchmarks"
    ) configs;
  List.rev !all_results
