open Eta_http_testsuite
open Types

module Yojson = Yojson.Safe

let ( let* ) = Result.bind

type run_size = Smoke | Quick | Full

type config = {
  size : run_size;
  include_references : bool;
  protocol_filter : Types.protocol option;
  capabilities_only : bool;
  out_dir : string option;
}

type method_ = Get | Post

type endpoint = {
  name : string;
  method_ : method_;
  path : string;
  body_bytes : int;
  expected_status : int;
  expected_body_bytes : int;
}

type mode = {
  server : Types.server_kind;
  protocol : Types.protocol;
  transport : Types.transport;
}

type run_shape = {
  duration : string option;
  requests : int option;
  timeout : string;
  concurrencies : int list;
  h2_matrix : (int * int) list;
  repeats : int;
  endpoints : endpoint list;
  modes : mode list;
}

type load_case = {
  total_concurrency : int;
  connections : int;
  streams_per_connection : int;
  scenario : string;
}

let quote = Filename.quote

let usage () =
  prerr_endline
    "usage: run.exe [--smoke|--quick|--full] [--references] \
     [--eta-only] [--h1-only|--h2-only] [--capabilities-only] [--out DIR]";
  exit 2

let parse_args argv =
  let rec loop config index =
    if index >= Array.length argv then config
    else
      match argv.(index) with
      | "--smoke" -> loop { config with size = Smoke } (index + 1)
      | "--quick" -> loop { config with size = Quick } (index + 1)
      | "--full" -> loop { config with size = Full } (index + 1)
      | "--references" ->
          loop { config with include_references = true } (index + 1)
      | "--eta-only" ->
          loop { config with include_references = false } (index + 1)
      | "--h1-only" ->
          loop { config with protocol_filter = Some H1 } (index + 1)
      | "--h2-only" ->
          loop { config with protocol_filter = Some H2 } (index + 1)
      | "--capabilities-only" ->
          loop { config with capabilities_only = true } (index + 1)
      | "--out" when index + 1 < Array.length argv ->
          loop { config with out_dir = Some argv.(index + 1) } (index + 2)
      | "--help" | "-h" -> usage ()
      | unknown ->
          prerr_endline ("unknown argument: " ^ unknown);
          usage ()
  in
  loop
    {
      size = Smoke;
      include_references = false;
      protocol_filter = None;
      capabilities_only = false;
      out_dir = None;
    }
    1

let server_name = function
  | Types.Eta -> "eta"
  | Nginx -> "nginx"
  | Caddy -> "caddy"
  | Node -> "node"
  | Go -> "go"

let protocol_name = function Types.H1 -> "h1" | H2 -> "h2"
let transport_name = function Types.Plain -> "plain" | TLS -> "tls"
let method_name = function Get -> "GET" | Post -> "POST"
let size_name = function Smoke -> "smoke" | Quick -> "quick" | Full -> "full"

let mode_id mode =
  Printf.sprintf "%s_%s_%s" (server_name mode.server)
    (protocol_name mode.protocol) (transport_name mode.transport)

let endpoint_id endpoint =
  Printf.sprintf "%s_%s_%s" (String.lowercase_ascii (method_name endpoint.method_))
    endpoint.name
    (if endpoint.body_bytes = 0 then "empty"
     else Printf.sprintf "%db" endpoint.body_bytes)

let url ~port mode endpoint =
  let scheme =
    match mode.transport with Types.Plain -> "http" | TLS -> "https"
  in
  Printf.sprintf "%s://127.0.0.1:%d%s" scheme port endpoint.path

let body_path ~temp_dir endpoint =
  Filename.concat temp_dir
    (Printf.sprintf "body-%s-%d.bin" endpoint.name endpoint.body_bytes)

let ensure_body_file ~temp_dir endpoint =
  if endpoint.body_bytes > 0 then
    Util.write_file (body_path ~temp_dir endpoint)
      (String.make endpoint.body_bytes 'x')

let root =
  {
    name = "root";
    method_ = Get;
    path = "/";
    body_bytes = 0;
    expected_status = 200;
    expected_body_bytes = 0;
  }

let user_id =
  {
    name = "user_id";
    method_ = Get;
    path = "/user/123";
    body_bytes = 0;
    expected_status = 200;
    expected_body_bytes = 3;
  }

let post_user =
  {
    name = "post_user";
    method_ = Post;
    path = "/user";
    body_bytes = 0;
    expected_status = 200;
    expected_body_bytes = 0;
  }

let static_1k =
  {
    name = "static_1k";
    method_ = Get;
    path = "/static/1k.bin";
    body_bytes = 0;
    expected_status = 200;
    expected_body_bytes = 1024;
  }

let static_1m =
  {
    name = "static_1m";
    method_ = Get;
    path = "/static/1m.bin";
    body_bytes = 0;
    expected_status = 200;
    expected_body_bytes = 1024 * 1024;
  }

let echo_1k =
  {
    name = "echo_1k";
    method_ = Post;
    path = "/echo";
    body_bytes = 1024;
    expected_status = 200;
    expected_body_bytes = 1024;
  }

let echo_1m =
  {
    name = "echo_1m";
    method_ = Post;
    path = "/echo";
    body_bytes = 1024 * 1024;
    expected_status = 200;
    expected_body_bytes = 1024 * 1024;
  }

let eta_modes =
  [
    { server = Types.Eta; protocol = H1; transport = Plain };
    { server = Eta; protocol = H1; transport = TLS };
    { server = Eta; protocol = H2; transport = TLS };
    { server = Eta; protocol = H2; transport = Plain };
  ]

let reference_modes =
  [
    { server = Types.Nginx; protocol = H1; transport = Plain };
    { server = Nginx; protocol = H1; transport = TLS };
    { server = Nginx; protocol = H2; transport = TLS };
    { server = Caddy; protocol = H2; transport = TLS };
    { server = Node; protocol = H1; transport = Plain };
    { server = Go; protocol = H1; transport = Plain };
  ]

let endpoint_supported mode endpoint =
  match (mode.server, endpoint.name) with
  | Types.Nginx, ("echo_1k" | "echo_1m") -> false
  | _ -> true

let endpoints_for_mode shape mode =
  List.filter (endpoint_supported mode) shape.endpoints

let shape config =
  let base_modes =
    if config.include_references then eta_modes @ reference_modes else eta_modes
  in
  let modes =
    List.filter
      (fun mode ->
        match config.protocol_filter with
        | None -> true
        | Some protocol -> mode.protocol = protocol)
      base_modes
  in
  match config.size with
  | Smoke ->
      {
        duration = None;
        requests = Some 20;
        timeout = "5s";
        concurrencies = [ 1 ];
        h2_matrix = [ (1, 1) ];
        repeats = 1;
        endpoints = [ root ];
        modes;
      }
  | Quick ->
      {
        duration = None;
        requests = Some 1000;
        timeout = "5s";
        concurrencies = [ 1; 16 ];
        h2_matrix = [ (1, 1); (1, 16); (4, 4); (16, 1) ];
        repeats = 1;
        endpoints = [ root; user_id; post_user; static_1k; echo_1k ];
        modes;
      }
  | Full ->
      {
        duration = None;
        requests = Some 10000;
        timeout = "10s";
        concurrencies = [ 1; 16; 64; 256 ];
        h2_matrix =
          List.concat_map
            (fun connections ->
              List.map
                (fun streams_per_connection ->
                  (connections, streams_per_connection))
                [ 1; 16; 64; 128 ])
            [ 1; 4; 16; 64 ];
        repeats = 3;
        endpoints =
          [ root; user_id; post_user; static_1k; static_1m; echo_1k; echo_1m ];
        modes;
      }

let json_string s = `String s
let json_int i = `Int i
let json_float f = `Float f
let json_bool b = `Bool b
let json_option f = function None -> `Null | Some value -> f value

let json_of_server server = json_string (server_name server)
let json_of_protocol protocol = json_string (protocol_name protocol)
let json_of_transport transport = json_string (transport_name transport)
let json_of_method method_ = json_string (method_name method_)

let assoc_find name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let rec json_number = function
  | `Int value -> Some (float value)
  | `Intlit value -> float_of_string_opt value
  | `Float value -> Some value
  | _ -> None

let json_int_value = function
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | `Float value -> Some (int_of_float value)
  | _ -> None

let member_number name json =
  match assoc_find name json with None -> None | Some value -> json_number value

let distribution_total = function
  | Some (`Assoc fields) ->
      List.fold_left
        (fun acc (_name, value) ->
          acc + Option.value ~default:0 (json_int_value value))
        0 fields
  | _ -> 0

let command_available name =
  match Util.run_cmd_out (Printf.sprintf "command -v %s 2>/dev/null" (quote name)) with
  | Ok (_ :: _) -> true
  | _ -> false

let command_first_line cmd =
  match Util.run_cmd_out (cmd ^ " 2>&1") with
  | Ok (line :: _) -> String.trim line
  | _ -> "unknown"

let git_dirty () =
  match Util.run_cmd_out "git status --porcelain --untracked-files=no" with
  | Ok [] -> false
  | Ok _ -> true
  | Error _ -> false

let capabilities_json () =
  `Assoc
    [
      ("oha", `Assoc [ ("available", json_bool (command_available "oha"));
                       ("version", json_string (command_first_line "oha --version")) ]);
      ("curl", `Assoc [ ("available", json_bool (command_available "curl"));
                        ("version", json_string (command_first_line "curl --version")) ]);
      ("openssl", `Assoc [ ("available", json_bool (command_available "openssl"));
                           ("version", json_string (command_first_line "openssl version")) ]);
      ("nghttp2", `Assoc [ ("available", json_bool (command_available "h2load"));
                           ("version", json_string (command_first_line "h2load --version")) ]);
      ("nginx", `Assoc [ ("available", json_bool (command_available "nginx"));
                         ("version", json_string (command_first_line "nginx -v")) ]);
      ("caddy", `Assoc [ ("available", json_bool (command_available "caddy"));
                         ("version", json_string (command_first_line "caddy version")) ]);
      ("node", `Assoc [ ("available", json_bool (command_available "node"));
                        ("version", json_string (command_first_line "node --version")) ]);
      ("go", `Assoc [ ("available", json_bool (command_available "go"));
                      ("version", json_string (command_first_line "go version")) ]);
    ]

let metadata_json config =
  `Assoc
    [
      ("schema_version", `Int 1);
      ("kind", `String "eta_http_server_load");
      ("run_size", json_string (size_name config.size));
      ("include_references", json_bool config.include_references);
      ( "protocol_filter",
        match config.protocol_filter with
        | None -> `Null
        | Some protocol -> json_string (protocol_name protocol) );
      ("git_sha", json_string (Util.git_sha ()));
      ("dirty", json_bool (git_dirty ()));
      ("started_at", json_string (Util.utc_timestamp ()));
      ("host", json_string (Util.hostname ()));
      ("os", json_string (Sys.os_type));
      ("kernel", json_string (command_first_line "uname -r"));
      ("cpu_model", json_string (command_first_line "awk -F: '/model name/ {gsub(/^ /, \"\", $2); print $2; exit}' /proc/cpuinfo"));
      ("cpu_count", json_string (command_first_line "getconf _NPROCESSORS_ONLN"));
      ("ocaml_version", json_string (command_first_line "ocamlc -version"));
      ("dune_version", json_string (command_first_line "dune --version"));
      ("eio_backend", json_string (Option.value ~default:"" (Sys.getenv_opt "EIO_BACKEND")));
    ]

let run_blocking label f = Eio_unix.run_in_systhread ~label f

let curl_protocol_flags mode =
  match (mode.protocol, mode.transport) with
  | Types.H1, _ -> "--http1.1"
  | H2, Plain -> "--http2-prior-knowledge"
  | H2, TLS -> "--http2"

let curl_preflight ~temp_dir ~mode ~endpoint ~url =
  ensure_body_file ~temp_dir endpoint;
  let body_out = Filename.concat temp_dir "preflight-body.out" in
  let method_flags =
    match endpoint.method_ with
    | Get -> ""
    | Post ->
        let body =
          if endpoint.body_bytes > 0 then
            " --data-binary @" ^ quote (body_path ~temp_dir endpoint)
          else ""
        in
        " -X POST -H " ^ quote "Content-Type: text/plain" ^ body
  in
  let tls_flag = match mode.transport with Types.Plain -> "" | TLS -> " -k" in
  let cmd =
    Printf.sprintf
      "curl -sS%s %s%s -o %s -w %%{http_code} %s 2>&1"
      tls_flag (curl_protocol_flags mode) method_flags (quote body_out)
      (quote url)
  in
  match run_blocking "curl-preflight" (fun () -> Util.run_cmd_out cmd) with
  | Error error -> Error error
  | Ok [ status_text ] -> (
      let status = int_of_string_opt (String.trim status_text) in
      let body_len =
        if Sys.file_exists body_out then String.length (Util.read_file body_out)
        else 0
      in
      match status with
      | Some status
        when status = endpoint.expected_status
             && body_len = endpoint.expected_body_bytes ->
          Ok (`Assoc [ ("status", `String "pass");
                       ("http_status", `Int status);
                       ("body_bytes", `Int body_len) ])
      | Some status ->
          Error
            (Printf.sprintf
               "preflight mismatch status=%d body_bytes=%d expected_status=%d \
                expected_body_bytes=%d"
               status body_len endpoint.expected_status endpoint.expected_body_bytes)
      | None -> Error ("bad curl status output: " ^ status_text))
  | Ok lines -> Error ("unexpected curl output: " ^ String.concat "\n" lines)

let oha_protocol_flags mode =
  match mode.protocol with
  | Types.H1 -> [ "--http-version"; "1.1" ]
  | H2 -> [ "--http-version"; "2" ]

let h1_load_case concurrency =
  {
    total_concurrency = concurrency;
    connections = concurrency;
    streams_per_connection = 1;
    scenario = "h1_multi_connection";
  }

let h2_load_case (connections, streams_per_connection) =
  {
    total_concurrency = connections * streams_per_connection;
    connections;
    streams_per_connection;
    scenario =
      (if connections = 1 then "h2_single_connection_multiplex"
       else "h2_multi_connection_multiplex");
  }

let load_cases_for_mode shape mode =
  match mode.protocol with
  | Types.H1 -> List.map h1_load_case shape.concurrencies
  | H2 -> List.map h2_load_case shape.h2_matrix

let oha_command ~temp_dir ~shape ~mode ~endpoint ~load_case ~repeat ~url =
  ensure_body_file ~temp_dir endpoint;
  let base =
    [
      "oha";
      "--no-tui";
      "--output-format";
      "json";
      "--redirect";
      "0";
      "--disable-compression";
      "--connect-timeout";
      "2s";
      "-t";
      shape.timeout;
      "-c";
      string_of_int load_case.connections;
    ]
  in
  let h2_parallel =
    match mode.protocol with
    | Types.H1 -> []
    | H2 -> [ "-p"; string_of_int load_case.streams_per_connection ]
  in
  let count =
    match (shape.requests, shape.duration) with
    | Some n, _ -> [ "-n"; string_of_int n ]
    | None, Some duration -> [ "-z"; duration; "-w" ]
    | None, None -> [ "-n"; "20" ]
  in
  let tls = match mode.transport with Types.Plain -> [] | TLS -> [ "--insecure" ] in
  let method_flags =
    match endpoint.method_ with
    | Get -> []
    | Post ->
        let body =
          if endpoint.body_bytes > 0 then
            [ "-D"; body_path ~temp_dir endpoint ]
          else []
        in
        [ "-m"; "POST"; "-T"; "text/plain" ] @ body
  in
  let tokens =
    base @ h2_parallel @ count @ oha_protocol_flags mode @ tls @ method_flags
    @ [ url ]
  in
  let command = String.concat " " (List.map quote tokens) ^ " 2>&1" in
  (command, repeat)

let result_identity_json ~mode ~endpoint ~load_case ~repeat =
  [
    ("server", json_of_server mode.server);
    ("protocol", json_of_protocol mode.protocol);
    ("transport", json_of_transport mode.transport);
    ("method", json_of_method endpoint.method_);
    ("path", json_string endpoint.path);
    ("endpoint", json_string endpoint.name);
    ("body_bytes", json_int endpoint.body_bytes);
    ("concurrency", json_int load_case.total_concurrency);
    ("connections", json_int load_case.connections);
    ("streams_per_connection", json_int load_case.streams_per_connection);
    ("http2_parallel", json_int load_case.streams_per_connection);
    ("load_scenario", json_string load_case.scenario);
    ("repeat", json_int repeat);
  ]

let pass_result ~mode ~endpoint ~shape ~load_case ~repeat ~url ~preflight
    ~command ~raw =
  let summary = Option.value ~default:`Null (assoc_find "summary" raw) in
  let latency = Option.value ~default:`Null (assoc_find "latencyPercentiles" raw) in
  let status_dist = assoc_find "statusCodeDistribution" raw in
  let error_dist = assoc_find "errorDistribution" raw in
  let total_requests = distribution_total status_dist in
  let errors = distribution_total error_dist in
  let success_rate = member_number "successRate" summary in
  let status =
    match success_rate with
    | Some rate when Float.equal rate 1.0 && errors = 0 -> "pass"
    | _ -> "fail"
  in
  `Assoc
    (result_identity_json ~mode ~endpoint ~load_case ~repeat
     @ [
         ("status", `String status);
         ("url", json_string url);
         ("duration", json_option json_string shape.duration);
         ("requests", json_option json_int shape.requests);
         ("preflight", preflight);
         ("command", json_string command);
         ( "error",
           if String.equal status "pass" then `Null
           else `String "oha reported failed requests" );
         ( "summary",
           `Assoc
             [
               ( "requests_per_sec",
                 json_option json_float (member_number "requestsPerSec" summary) );
               ( "success_rate",
                 json_option json_float success_rate );
               ("total_seconds", json_option json_float (member_number "total" summary));
               ("total_data_bytes", json_option json_float (member_number "totalData" summary));
               ("bytes_per_sec", json_option json_float (member_number "sizePerSec" summary));
               ("total_requests", json_int total_requests);
               ("errors", json_int errors);
             ] );
         ( "latency_seconds",
           `Assoc
             [
               ("mean", json_option json_float (member_number "average" summary));
               ("p50", json_option json_float (member_number "p50" latency));
               ("p90", json_option json_float (member_number "p90" latency));
               ("p95", json_option json_float (member_number "p95" latency));
               ("p99", json_option json_float (member_number "p99" latency));
               ("max", json_option json_float (member_number "slowest" summary));
             ] );
         ("raw_oha", raw);
       ])

let fail_result ~mode ~endpoint ~shape ~load_case ~repeat ~url ?preflight
    ~command error =
  `Assoc
    (result_identity_json ~mode ~endpoint ~load_case ~repeat
     @ [
         ("status", `String "fail");
         ("url", json_string url);
         ("duration", json_option json_string shape.duration);
         ("requests", json_option json_int shape.requests);
         ("preflight", Option.value ~default:`Null preflight);
         ("command", json_string command);
         ("error", json_string error);
       ])

let skip_result ~mode ~endpoint ~shape ~load_case ~repeat reason =
  `Assoc
    (result_identity_json ~mode ~endpoint ~load_case ~repeat
     @ [
         ("status", `String "skip");
         ("duration", json_option json_string shape.duration);
         ("requests", json_option json_int shape.requests);
         ("reason", json_string reason);
       ])

let run_oha ~shape ~temp_dir ~mode ~endpoint ~load_case ~repeat ~url =
  let command, repeat = oha_command ~temp_dir ~shape ~mode ~endpoint ~load_case
      ~repeat ~url
  in
  let preflight =
    match curl_preflight ~temp_dir ~mode ~endpoint ~url with
    | Ok json -> Ok json
    | Error error -> Error error
  in
  match preflight with
  | Error error ->
      fail_result ~mode ~endpoint ~shape ~load_case ~repeat ~url
        ~command error
  | Ok preflight -> (
      match
        run_blocking "oha" (fun () ->
            Util.run_cmd_out ~env:[ ("NO_COLOR", "false") ] command)
      with
      | Error error ->
          fail_result ~mode ~endpoint ~shape ~load_case ~repeat ~url
            ~preflight ~command error
      | Ok lines -> (
          let output = String.concat "\n" lines in
          match Yojson.from_string output with
          | raw ->
              pass_result ~mode ~endpoint ~shape ~load_case ~repeat ~url
                ~preflight ~command ~raw
          | exception exn ->
              fail_result ~mode ~endpoint ~shape ~load_case ~repeat ~url
                ~preflight ~command
                (Printf.sprintf "oha JSON parse failed: %s\n%s"
                   (Printexc.to_string exn) output)))

let wait_http_ready ~port ~deadline_ms =
  let start = Util.now_ms () in
  let rec poll () =
    let now = Util.now_ms () in
    if now -. start > deadline_ms then Error "server readiness poll timed out"
    else
      match
        Util.run_cmd_out
          (Printf.sprintf
             "curl -s -o /dev/null -w %%{http_code} http://127.0.0.1:%d/healthz"
             port)
      with
      | Ok [ "200" ] -> Ok ()
      | _ ->
          Unix.sleepf 0.05;
          poll ()
  in
  poll ()

let node_server_source =
  {|const http = require("http");
const fs = require("fs");
const path = require("path");

const port = Number(process.argv[2]);
const root = process.argv[3];

function collect(req, cb) {
  const chunks = [];
  req.on("data", chunk => chunks.push(chunk));
  req.on("end", () => cb(Buffer.concat(chunks)));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200);
    res.end();
  } else if (req.method === "GET" && url.pathname === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok\n");
  } else if (req.method === "GET" && url.pathname.startsWith("/user/")) {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end(url.pathname.slice("/user/".length));
  } else if (req.method === "POST" && url.pathname === "/user") {
    collect(req, () => {
      res.writeHead(200);
      res.end();
    });
  } else if (req.method === "POST" && url.pathname === "/echo") {
    collect(req, body => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end(body);
    });
  } else if (req.method === "GET" && url.pathname.startsWith("/static/")) {
    const file = path.join(root, url.pathname.slice("/static/".length));
    fs.readFile(file, (err, data) => {
      if (err) {
        res.writeHead(404);
        res.end();
      } else {
        res.writeHead(200);
        res.end(data);
      }
    });
  } else {
    res.writeHead(404);
    res.end();
  }
});

server.listen(port, "127.0.0.1");
|}

let go_server_source =
  {|package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func main() {
	port, err := strconv.Atoi(os.Args[1])
	if err != nil {
		panic(err)
	}
	root := os.Args[2]

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case r.Method == "GET" && path == "/":
			w.WriteHeader(http.StatusOK)
		case r.Method == "GET" && path == "/healthz":
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte("ok\n"))
		case r.Method == "GET" && strings.HasPrefix(path, "/user/"):
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte(strings.TrimPrefix(path, "/user/")))
		case r.Method == "POST" && path == "/user":
			_, _ = io.Copy(io.Discard, r.Body)
			w.WriteHeader(http.StatusOK)
		case r.Method == "POST" && path == "/echo":
			body, err := io.ReadAll(r.Body)
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write(body)
		case r.Method == "GET" && strings.HasPrefix(path, "/static/"):
			http.ServeFile(w, r, filepath.Join(root, strings.TrimPrefix(path, "/static/")))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})

	panic(http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", port), nil))
}
|}

let start_pid_command ~command ~pid_path ~log_path =
  Util.run_cmd
    (Printf.sprintf "%s >%s 2>&1 & echo $! >%s" command (quote log_path)
       (quote pid_path))

let start_node_server ~port ~temp_dir ~protocol ~transport =
  match (protocol, transport) with
  | Types.H1, Plain ->
      let source_path = Filename.concat temp_dir "node_h1_server.js" in
      let pid_path = Filename.concat temp_dir "node.pid" in
      let log_path = Filename.concat temp_dir "node.log" in
      Util.write_file source_path node_server_source;
      let command =
        Printf.sprintf "node %s %d %s" (quote source_path) port
          (quote (Util.absolute_path temp_dir))
      in
      let* () = start_pid_command ~command ~pid_path ~log_path in
      let* () = wait_http_ready ~port ~deadline_ms:5000.0 in
      Ok pid_path
  | _ -> Error "node reference supports only HTTP/1.1 plain"

let start_go_server ~port ~temp_dir ~protocol ~transport =
  match (protocol, transport) with
  | Types.H1, Plain ->
      let source_path = Filename.concat temp_dir "go_h1_server.go" in
      let bin_path = Filename.concat temp_dir "go_h1_server" in
      let pid_path = Filename.concat temp_dir "go.pid" in
      let log_path = Filename.concat temp_dir "go.log" in
      Util.write_file source_path go_server_source;
      let* () =
        Util.run_cmd
          (Printf.sprintf "go build -o %s %s" (quote bin_path)
             (quote source_path))
      in
      let command =
        Printf.sprintf "%s %d %s" (quote bin_path) port
          (quote (Util.absolute_path temp_dir))
      in
      let* () = start_pid_command ~command ~pid_path ~log_path in
      let* () = wait_http_ready ~port ~deadline_ms:5000.0 in
      Ok pid_path
  | _ -> Error "go reference supports only HTTP/1.1 plain"

let stop_pid_file pid_path =
  if Sys.file_exists pid_path then
    match Util.run_cmd_out (Printf.sprintf "cat %s" (quote pid_path)) with
    | Ok (pid :: _) -> (
        let pid = int_of_string (String.trim pid) in
        (try Unix.kill pid Sys.sigterm with _ -> ());
        let rec wait attempts =
          if attempts <= 0 then ()
          else
            try
              Unix.kill pid 0;
              Unix.sleepf 0.05;
              wait (attempts - 1)
            with _ -> ()
        in
        wait 40)
    | _ -> ()

let start_external_server mode ~port ~temp_dir ~cert_dir =
  match mode.server with
  | Types.Nginx ->
      Nginx.start ~port ~temp_dir ~cert_dir ~protocol:mode.protocol
        ~transport:mode.transport
  | Caddy ->
      Caddy.start ~port ~temp_dir ~cert_dir ~protocol:mode.protocol
        ~transport:mode.transport
  | Node ->
      start_node_server ~port ~temp_dir ~protocol:mode.protocol
        ~transport:mode.transport
  | Go ->
      start_go_server ~port ~temp_dir ~protocol:mode.protocol
        ~transport:mode.transport
  | Eta -> Error "internal error: Eta is not an external server"

let stop_external_server mode pid_path =
  match mode.server with
  | Types.Nginx -> ignore (Nginx.stop pid_path)
  | Caddy -> ignore (Caddy.stop pid_path)
  | Node | Go -> stop_pid_file pid_path
  | Eta -> ()

let cert_dir_for ~temp_dir mode =
  match mode.transport with
  | Types.Plain -> ""
  | TLS -> (
      match Certs.prepare ~temp_dir with
      | Ok dir -> dir
      | Error error -> failwith ("cert generation failed: " ^ error))

let all_combinations shape mode =
  endpoints_for_mode shape mode
  |> List.concat_map
    (fun endpoint ->
      List.concat_map
        (fun load_case ->
          List.init shape.repeats (fun index -> (endpoint, load_case, index + 1)))
        (load_cases_for_mode shape mode))

let skipped_mode_results shape mode reason =
  all_combinations shape mode
  |> List.map (fun (endpoint, load_case, repeat) ->
         skip_result ~mode ~endpoint ~shape ~load_case ~repeat reason)

let run_started_mode ~shape ~temp_dir ~mode ~port =
  endpoints_for_mode shape mode
  |> List.iter (ensure_body_file ~temp_dir);
  endpoints_for_mode shape mode
  |> List.concat_map
    (fun endpoint ->
      List.concat_map
        (fun load_case ->
          List.init shape.repeats (fun index ->
              let repeat = index + 1 in
              let url = url ~port mode endpoint in
              Printf.printf
                "  %-18s %-8s %-4s c=%-4d conn=%-4d streams=%-4d %s repeat=%d\n%!"
                (mode_id mode) endpoint.name (method_name endpoint.method_)
                load_case.total_concurrency load_case.connections
                load_case.streams_per_connection endpoint.path repeat;
              run_oha ~shape ~temp_dir ~mode ~endpoint ~load_case ~repeat
                ~url))
        (load_cases_for_mode shape mode))

let run_mode ~env ~clock ~results_dir shape mode =
  let temp_dir = Filename.concat results_dir (mode_id mode) in
  Util.mkdir_p temp_dir;
  ignore (Fixtures.generate ~dir:temp_dir);
  let port = Util.random_port () in
  try
    let cert_dir = cert_dir_for ~temp_dir mode in
    match mode.server with
    | Types.Eta ->
        Eio.Switch.run (fun sw ->
            match
              Eta_server.start ~sw ~env ~port ~temp_dir
                ?cert_dir:(if cert_dir = "" then None else Some cert_dir)
                ~protocol:mode.protocol ~transport:mode.transport ()
            with
            | Error error -> skipped_mode_results shape mode error
            | Ok server ->
                Eio.Time.sleep clock 0.05;
                Fun.protect
                  ~finally:(fun () -> ignore (Eta_server.stop server))
                  (fun () -> run_started_mode ~shape ~temp_dir ~mode ~port))
    | Nginx | Caddy | Node | Go -> (
        match start_external_server mode ~port ~temp_dir ~cert_dir with
        | Error error -> skipped_mode_results shape mode error
        | Ok pid_path ->
            Fun.protect
              ~finally:(fun () -> stop_external_server mode pid_path)
              (fun () -> run_started_mode ~shape ~temp_dir ~mode ~port))
  with exn -> skipped_mode_results shape mode (Printexc.to_string exn)

let config_json shape =
  `Assoc
    [
      ("duration", json_option json_string shape.duration);
      ("requests", json_option json_int shape.requests);
      ("timeout", json_string shape.timeout);
      ("concurrencies", `List (List.map json_int shape.concurrencies));
      ( "h2_matrix",
        `List
          (List.map
             (fun (connections, streams_per_connection) ->
               `Assoc
                 [
                   ("connections", json_int connections);
                   ("streams_per_connection", json_int streams_per_connection);
                   ( "total_concurrency",
                     json_int (connections * streams_per_connection) );
                 ])
             shape.h2_matrix) );
      ("repeats", json_int shape.repeats);
      ( "endpoints",
        `List
          (List.map
             (fun endpoint ->
               `Assoc
                 [
                   ("name", json_string endpoint.name);
                   ("method", json_of_method endpoint.method_);
                   ("path", json_string endpoint.path);
                   ("body_bytes", json_int endpoint.body_bytes);
                   ("expected_status", json_int endpoint.expected_status);
                   ("expected_body_bytes", json_int endpoint.expected_body_bytes);
                 ])
             shape.endpoints) );
      ( "modes",
        `List
          (List.map
             (fun mode ->
               `Assoc
                 [
                   ("server", json_of_server mode.server);
                   ("protocol", json_of_protocol mode.protocol);
                   ("transport", json_of_transport mode.transport);
                 ])
             shape.modes) );
    ]

let results_dir config =
  match config.out_dir with
  | Some dir -> dir
  | None ->
      Filename.concat "http-testsuite/results"
        (Printf.sprintf "%s-%s-server-load" (Util.utc_timestamp ())
           (Util.git_sha ()))

let report_json config shape results =
  `Assoc
    [
      ("metadata", metadata_json config);
      ("capabilities", capabilities_json ());
      ("config", config_json shape);
      ("results", `List results);
    ]

let () =
  let config = parse_args Sys.argv in
  let shape = shape config in
  let results_dir = results_dir config in
  Util.mkdir_p results_dir;
  let results_path = Filename.concat results_dir "server_load.json" in
  let results =
    if config.capabilities_only then []
    else
      Eio_main.run @@ fun env ->
      let clock = Eio.Stdenv.clock env in
      List.concat_map
        (fun mode ->
          Printf.printf "server_load mode=%s\n%!" (mode_id mode);
          run_mode ~env ~clock ~results_dir shape mode)
        shape.modes
  in
  Eta_http_testsuite.Json.write_json ~path:results_path
    (report_json config shape results);
  Printf.printf "server_load results=%s\n%!" results_path
