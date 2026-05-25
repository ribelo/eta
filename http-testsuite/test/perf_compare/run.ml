(* Apples-to-apples HTTP client performance comparison.

   Eta and Go both run as warm in-process clients with reused transports.
   Curl is reported separately as a process-per-request CLI reference. *)

open Eta_http_testsuite
open Types

type method_ = Get | Post

type scenario = {
  name : string;
  server : Types.server_kind;
  protocol : Types.protocol;
  transport : Types.transport;
  path : string;
  method_ : method_;
  body_bytes : int;
  iterations : int;
}

type sample_set = {
  scenario : scenario;
  client : string;
  samples_ns : int64 list;
  error : string option;
}

let env_int name default =
  match Sys.getenv_opt name with
  | None | Some "" -> default
  | Some s -> (
      match int_of_string_opt (String.trim s) with
      | Some n -> n
      | None -> default)

let warmup_iterations = env_int "ETA_PERF_WARMUP" 10
let iterations_override = env_int "ETA_PERF_ITERS" 0
let timeout_ms = env_int "ETA_PERF_TIMEOUT_MS" 2000

let effective_iterations scenario_iters =
  if iterations_override > 0 then iterations_override else scenario_iters

let server_name = function
  | Types.Nginx -> "nginx"
  | Caddy -> "caddy"

let protocol_name = function
  | Types.H1 -> "h1"
  | H2 -> "h2"

let transport_name = function
  | Types.Plain -> "plain"
  | TLS -> "tls"

let method_name = function
  | Get -> "GET"
  | Post -> "POST"

let scenario_id s =
  Printf.sprintf "%s_%s_%s_%s" (server_name s.server)
    (protocol_name s.protocol) (transport_name s.transport) s.name

let url ~port scenario =
  let scheme =
    match scenario.transport with
    | Types.Plain -> "http"
    | TLS -> "https"
  in
  Printf.sprintf "%s://127.0.0.1:%d%s" scheme port scenario.path

let make_eta_client ~env ~sw ~protocol ~_transport ~_cert_dir =
  let max_response_body_bytes = 128 * 1024 * 1024 in
  match protocol with
  | Types.H1 ->
      Eta_http.Client.make_h1 ~sw ~net:(Eio.Stdenv.net env)
        ~max_response_body_bytes ()
  | H2 ->
      Eta_http.Client.make ~sw ~net:(Eio.Stdenv.net env)
        ~max_response_body_bytes ()

let headers_for = function
  | Get -> Eta_http.Core.Header.empty
  | Post -> (
      match Eta_http.Core.Header.of_list [ ("Content-Type", "text/plain") ] with
      | Ok h -> h
      | Error _ -> Eta_http.Core.Header.empty)

let make_eta_request scenario url body =
  let request_body =
    match scenario.method_ with
    | Get -> Eta_http.Request.Empty
    | Post -> Eta_http.Request.Fixed [ Bytes.of_string body ]
  in
  Eta_http.Request.make ~headers:(headers_for scenario.method_) ~body:request_body
    (method_name scenario.method_) url

let consume_eta_response (response : Eta_http.Response.t) =
  Util.body_to_string response.body
  |> Eta.Effect.map (fun body -> (response.status, String.length body))

let eta_protocol = function
  | Types.H1 -> Eta_http.Error.H1
  | H2 -> H2

let eta_timeout_error scenario url =
  Eta_http.Error.make ~protocol:(eta_protocol scenario.protocol)
    ~method_:(method_name scenario.method_) ~uri:url
    (Total_request_timeout { timeout_ms = Some timeout_ms })

let run_eta_once ~rt ~client ~scenario ~url request =
  let t0 = Unix.gettimeofday () in
  let result =
    Eta_http.request client request
    |> Eta.Effect.bind consume_eta_response
    |> Eta.Effect.timeout_as (Eta.Duration.ms timeout_ms)
         ~on_timeout:(eta_timeout_error scenario url)
    |> Eta.Runtime.run rt
  in
  let t1 = Unix.gettimeofday () in
  match result with
  | Eta.Exit.Ok (200, _body_length) ->
      Int64.of_float ((t1 -. t0) *. 1_000_000_000.0)
  | Eta.Exit.Ok (status, _body_length) ->
      failwith (Printf.sprintf "eta returned status %d" status)
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "eta request failed: %a"
           (Eta.Cause.pp Eta_http.Error.pp)
           cause)

let run_eta ~env ~scenario ~url ~cert_dir =
  let samples = ref [] in
  Eio.Switch.run (fun sw ->
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
      let client =
        make_eta_client ~env ~sw ~protocol:scenario.protocol
          ~_transport:scenario.transport ~_cert_dir:cert_dir
      in
      let body = String.make scenario.body_bytes 'x' in
      for _ = 1 to warmup_iterations do
        let request = make_eta_request scenario url body in
        ignore (run_eta_once ~rt ~client ~scenario ~url request)
      done;
      let iters = effective_iterations scenario.iterations in
      for i = 1 to iters do
        if i mod 10 = 0 then Printf.printf "    eta %d/%d\n%!" i iters;
        let request = make_eta_request scenario url body in
        samples := run_eta_once ~rt ~client ~scenario ~url request :: !samples
      done;
      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client)));
  List.rev !samples

let go_source =
  {|
package main

import (
  "bytes"
  "crypto/tls"
  "fmt"
  "io"
  "net/http"
  "os"
  "strconv"
  "time"
)

func die(format string, args ...any) {
  fmt.Fprintf(os.Stderr, format+"\\n", args...)
  os.Exit(1)
}

func main() {
  if len(os.Args) != 8 {
    die("usage: go_http_loop METHOD URL PROTOCOL INSECURE BODY_BYTES WARMUP ITERS")
  }

  method := os.Args[1]
  url := os.Args[2]
  protocol := os.Args[3]
  insecure := os.Args[4] == "true"
  bodyBytes, err := strconv.Atoi(os.Args[5])
  if err != nil {
    die("bad BODY_BYTES: %v", err)
  }
  warmup, err := strconv.Atoi(os.Args[6])
  if err != nil {
    die("bad WARMUP: %v", err)
  }
  iters, err := strconv.Atoi(os.Args[7])
  if err != nil {
    die("bad ITERS: %v", err)
  }

  tlsConfig := &tls.Config{InsecureSkipVerify: insecure}
  if protocol == "h2" {
    tlsConfig.NextProtos = []string{"h2", "http/1.1"}
  } else {
    tlsConfig.NextProtos = []string{"http/1.1"}
  }

  transport := &http.Transport{
    ForceAttemptHTTP2: protocol == "h2",
    TLSClientConfig: tlsConfig,
    MaxIdleConns: 100,
    MaxIdleConnsPerHost: 100,
  }
  if protocol == "h1" {
    transport.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
  }
  client := &http.Client{Transport: transport}
  body := bytes.Repeat([]byte("x"), bodyBytes)

  run := func(print bool) {
    var reader io.Reader
    if method == "POST" {
      reader = bytes.NewReader(body)
    }
    req, err := http.NewRequest(method, url, reader)
    if err != nil {
      die("new request: %v", err)
    }
    if method == "POST" {
      req.Header.Set("Content-Type", "text/plain")
      req.ContentLength = int64(len(body))
    }

    start := time.Now()
    resp, err := client.Do(req)
    if err != nil {
      die("request: %v", err)
    }
    _, err = io.Copy(io.Discard, resp.Body)
    closeErr := resp.Body.Close()
    elapsed := time.Since(start)
    if err != nil {
      die("read body: %v", err)
    }
    if closeErr != nil {
      die("close body: %v", closeErr)
    }
    if resp.StatusCode != 200 {
      die("status: %d", resp.StatusCode)
    }
    if print {
      fmt.Println(elapsed.Nanoseconds())
    }
  }

  for i := 0; i < warmup; i++ {
    run(false)
  }
  for i := 0; i < iters; i++ {
    run(true)
  }
}
|}

let build_go_helper temp_dir =
  let source = Filename.concat temp_dir "go_http_loop.go" in
  let exe = Filename.concat temp_dir "go_http_loop" in
  Util.write_file source go_source;
  let cmd =
    Printf.sprintf "cd %s && go build -o %s %s" (Filename.quote temp_dir)
      (Filename.quote (Filename.basename exe))
      (Filename.quote (Filename.basename source))
  in
  match Util.run_cmd cmd with
  | Ok () -> exe
  | Error e -> failwith e

let parse_go_samples lines =
  List.map
    (fun line ->
      try Int64.of_string (String.trim line)
      with Failure _ -> failwith ("bad go sample: " ^ line))
    lines

let run_go ~go_helper ~scenario ~url =
  let cmd =
    Printf.sprintf "%s %s %s %s %s %d %d %d"
      (Filename.quote go_helper)
      (Filename.quote (method_name scenario.method_))
      (Filename.quote url)
      (Filename.quote (protocol_name scenario.protocol))
      (match scenario.transport with Types.Plain -> "false" | TLS -> "true")
      scenario.body_bytes warmup_iterations
      (effective_iterations scenario.iterations)
  in
  match Util.run_cmd_out cmd with
  | Ok lines -> parse_go_samples lines
  | Error e -> failwith e

let run_curl_once ~scenario ~url ~body_path =
  let protocol_flag =
    match scenario.protocol with
    | Types.H1 -> "--http1.1"
    | H2 -> "--http2"
  in
  let tls_flag =
    match scenario.transport with
    | Types.Plain -> ""
    | TLS -> "-k"
  in
  let method_flags =
    match scenario.method_ with
    | Get -> ""
    | Post ->
        Printf.sprintf "-H %s --data-binary @%s"
          (Filename.quote "Content-Type: text/plain")
          (Filename.quote body_path)
  in
  let cmd =
    Printf.sprintf "curl -s -o /dev/null %s %s %s %s" tls_flag protocol_flag
      method_flags (Filename.quote url)
  in
  let t0 = Unix.gettimeofday () in
  let result = Sys.command cmd in
  let t1 = Unix.gettimeofday () in
  if result <> 0 then failwith (Printf.sprintf "curl failed: %s" cmd);
  Int64.of_float ((t1 -. t0) *. 1_000_000_000.0)

let run_curl_cli ~scenario ~url ~temp_dir =
  let body_path = Filename.concat temp_dir "curl_body" in
  if scenario.body_bytes > 0 then
    Util.write_file body_path (String.make scenario.body_bytes 'x');
  for _ = 1 to warmup_iterations do
    ignore (run_curl_once ~scenario ~url ~body_path)
  done;
  List.init (effective_iterations scenario.iterations)
    (fun _ -> run_curl_once ~scenario ~url ~body_path)

let start_server scenario ~temp_dir =
  ignore (Fixtures.generate ~dir:temp_dir);
  let port = Util.random_port () in
  let cert_dir =
    match scenario.transport with
    | Types.Plain -> None
    | TLS -> (
        match Certs.prepare ~temp_dir with
        | Ok d -> Some d
        | Error e -> failwith ("cert generation failed: " ^ e))
  in
  let cert_dir_str = Option.value ~default:"" cert_dir in
  let pid_path =
    match scenario.server with
    | Types.Nginx ->
        Nginx.start ~port ~temp_dir ~cert_dir:cert_dir_str
          ~protocol:scenario.protocol ~transport:scenario.transport
    | Caddy ->
        Caddy.start ~port ~temp_dir ~cert_dir:cert_dir_str
          ~protocol:scenario.protocol ~transport:scenario.transport
  in
  match pid_path with
  | Ok pid_path -> (port, cert_dir_str, pid_path)
  | Error e -> failwith e

let stop_server scenario pid_path =
  match scenario.server with
  | Types.Nginx -> ignore (Nginx.stop pid_path)
  | Caddy -> ignore (Caddy.stop pid_path)

let run_scenario ~env ~results_dir scenario =
  let temp_dir = Filename.concat results_dir (scenario_id scenario) in
  Util.mkdir_p temp_dir;
  let port, cert_dir, pid_path = start_server scenario ~temp_dir in
  Fun.protect
    ~finally:(fun () -> stop_server scenario pid_path)
    (fun () ->
      let url = url ~port scenario in
      let go_helper = build_go_helper temp_dir in
      let run_client client f =
        Printf.printf "  %s\n%!" client;
        try { scenario; client; samples_ns = f (); error = None }
        with exn ->
          {
            scenario;
            client;
            samples_ns = [];
            error = Some (Printexc.to_string exn);
          }
      in
      let eta =
        run_client "eta_warm" (fun () -> run_eta ~env ~scenario ~url ~cert_dir)
      in
      let go = run_client "go_warm" (fun () -> run_go ~go_helper ~scenario ~url) in
      let curl =
        run_client "curl_cli" (fun () -> run_curl_cli ~scenario ~url ~temp_dir)
      in
      [ eta; go; curl ])

let percentile p samples =
  match List.sort Int64.compare samples with
  | [] -> 0L
  | sorted ->
      let len = List.length sorted in
      let idx =
        int_of_float (ceil ((p /. 100.0) *. float len)) - 1
        |> max 0 |> min (len - 1)
      in
      List.nth sorted idx

let mean samples =
  match samples with
  | [] -> 0.0
  | _ ->
      let total =
        List.fold_left
          (fun acc sample -> acc +. Int64.to_float sample)
          0.0 samples
      in
      total /. float (List.length samples)

let ms ns = Int64.to_float ns /. 1_000_000.0
let mean_ms samples = mean samples /. 1_000_000.0

let render_row set =
  match set.error with
  | Some error ->
      Printf.sprintf "%-34s %-9s %7s %7s %7s %4d  ERROR %s"
        (scenario_id set.scenario) set.client "-" "-" "-" 0 error
  | None ->
      let median = percentile 50.0 set.samples_ns in
      let p95 = percentile 95.0 set.samples_ns in
      Printf.sprintf "%-34s %-9s %7.3f %7.3f %7.3f %4d"
        (scenario_id set.scenario) set.client (ms median) (ms p95)
        (mean_ms set.samples_ns) (List.length set.samples_ns)

let write_json ~path sets =
  let sample_json samples =
    `List (List.map (fun ns -> `Intlit (Int64.to_string ns)) samples)
  in
  let row set =
    `Assoc
      [
        ("scenario", `String (scenario_id set.scenario));
        ("server", `String (server_name set.scenario.server));
        ("protocol", `String (protocol_name set.scenario.protocol));
        ("transport", `String (transport_name set.scenario.transport));
        ("method", `String (method_name set.scenario.method_));
        ("path", `String set.scenario.path);
        ("body_bytes", `Int set.scenario.body_bytes);
        ("client", `String set.client);
        ("warmup_iterations", `Int warmup_iterations);
        ("error", (match set.error with None -> `Null | Some e -> `String e));
        ("samples_ns", sample_json set.samples_ns);
        ("median_ns", `Intlit (Int64.to_string (percentile 50.0 set.samples_ns)));
        ("p95_ns", `Intlit (Int64.to_string (percentile 95.0 set.samples_ns)));
        ("mean_ns", `Float (mean set.samples_ns));
      ]
  in
  Json.write_json ~path (`List (List.map row sets))

let scenarios =
  [
    {
      name = "get_1k";
      server = Types.Nginx;
      protocol = H1;
      transport = Plain;
      path = "/static/1k.bin";
      method_ = Get;
      body_bytes = 0;
      iterations = 50;
    };
    {
      name = "get_1k";
      server = Nginx;
      protocol = H2;
      transport = TLS;
      path = "/static/1k.bin";
      method_ = Get;
      body_bytes = 0;
      iterations = 50;
    };
    {
      name = "get_1m";
      server = Nginx;
      protocol = H2;
      transport = TLS;
      path = "/static/1m.bin";
      method_ = Get;
      body_bytes = 0;
      iterations = 20;
    };
    {
      name = "post_1m";
      server = Caddy;
      protocol = H2;
      transport = TLS;
      path = "/echo";
      method_ = Post;
      body_bytes = 1024 * 1024;
      iterations = 20;
    };
  ]

let () =
  let run_id =
    Printf.sprintf "%s-%s-perf-compare" (Util.utc_timestamp ()) (Util.git_sha ())
  in
  let results_dir = Filename.concat "http-testsuite/results" run_id in
  Util.mkdir_p results_dir;
  Printf.printf "perf_compare run_id=%s results_dir=%s\n%!" run_id results_dir;
  Eio_main.run @@ fun env ->
  let sets =
    List.concat_map
      (fun scenario ->
        Printf.printf "running %s\n%!" (scenario_id scenario);
        run_scenario ~env ~results_dir scenario)
      scenarios
  in
  write_json ~path:(Filename.concat results_dir "perf_compare.json") sets;
  Printf.printf "%-34s %-9s %7s %7s %7s %4s\n" "scenario" "client" "median"
    "p95" "mean" "n";
  List.iter (fun set -> Printf.printf "%s\n" (render_row set)) sets;
  Printf.printf "perf_compare done results_dir=%s\n%!" results_dir
