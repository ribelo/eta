(* Benchmark suite.
   Runs a subset of interop scenarios N iterations and captures latency,
   GC allocation, and RSS metrics for both eta-http and curl. *)

open Types
open Eio.Std

let minor_words (x, _, _, _) = x
let major_words (_, x, _, _) = x
let promoted_words (_, _, x, _) = x
let top_heap_words (_, _, _, x) = x

let make_eta_client ~env ~sw ~protocol ~transport ~cert_dir =
  let max_response_body_bytes = 128 * 1024 * 1024 in
  let authenticator =
    match transport with
    | Plain -> None
    | TLS ->
        let dir = Eio.Path.(Eio.Stdenv.cwd env / cert_dir) in
        Some (X509_eio.authenticator (`Ca_file Eio.Path.(dir / "ca.pem")))
  in
  match protocol with
  | H1 ->
      Eta_http.Client.make_h1 ~sw ~net:(Eio.Stdenv.net env)
        ?authenticator ~max_response_body_bytes ()
  | H2 ->
      Eta_http.Client.make ~sw ~net:(Eio.Stdenv.net env)
        ?authenticator ~max_response_body_bytes ()

let run_eta_get ~rt ~client ~url =
  let request =
    let headers =
      match Eta_http.Core.Header.of_list [] with
      | Ok h -> h
      | Error _ -> Eta_http.Core.Header.empty
    in
    Eta_http.Request.make ~headers "GET" url
  in
  let gc_before = Util.gc_stat () in
  let rss_before = Util.rss_kb () in
  let t0 = Unix.gettimeofday () in
  let result =
    Eta_http.request client request
    |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
           Util.body_to_string response.body
           |> Eta.Effect.bind (fun _body ->
                  Eta.Effect.pure (Ok response.status)))
    |> Eta.Runtime.run rt
  in
  let t1 = Unix.gettimeofday () in
  let rss_after = Util.rss_kb () in
  let gc_after = Util.gc_stat () in
  ignore (result);
  { scenario = ""; client = "eta"; iteration = 0;
    duration_ns = Int64.of_float ((t1 -. t0) *. 1_000_000_000.0);
    minor_words = minor_words gc_after -. minor_words gc_before;
    major_words = major_words gc_after -. major_words gc_before;
    promoted_words = promoted_words gc_after -. promoted_words gc_before;
    top_heap_words = top_heap_words gc_after;
    rss_kb = max rss_before rss_after }

let run_eta_post ~rt ~client ~url ~body_bytes =
  let body = Eta_http.Request.Fixed [ Bytes.of_string body_bytes ] in
  let request =
    let headers =
      match Eta_http.Core.Header.of_list [("Content-Type", "text/plain")] with
      | Ok h -> h
      | Error _ -> Eta_http.Core.Header.empty
    in
    Eta_http.Request.make ~headers ~body "POST" url
  in
  let gc_before = Util.gc_stat () in
  let rss_before = Util.rss_kb () in
  let t0 = Unix.gettimeofday () in
  let result =
    Eta_http.request client request
    |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
           Util.body_to_string response.body
           |> Eta.Effect.bind (fun _body ->
                  Eta.Effect.pure (Ok response.status)))
    |> Eta.Runtime.run rt
  in
  let t1 = Unix.gettimeofday () in
  let rss_after = Util.rss_kb () in
  let gc_after = Util.gc_stat () in
  ignore (result);
  { scenario = ""; client = "eta"; iteration = 0;
    duration_ns = Int64.of_float ((t1 -. t0) *. 1_000_000_000.0);
    minor_words = minor_words gc_after -. minor_words gc_before;
    major_words = major_words gc_after -. major_words gc_before;
    promoted_words = promoted_words gc_after -. promoted_words gc_before;
    top_heap_words = top_heap_words gc_after;
    rss_kb = max rss_before rss_after }

let run_curl_get ~url ~insecure ~http2 ~tmp_dir =
  let rss_before = Util.rss_kb () in
  let t0 = Unix.gettimeofday () in
  let _result =
    Curl.run ~url ~method_:"GET" ~headers:[] ~body_path:None ~insecure ~http2 ~tmp_dir
  in
  let t1 = Unix.gettimeofday () in
  let rss_after = Util.rss_kb () in
  { scenario = ""; client = "curl"; iteration = 0;
    duration_ns = Int64.of_float ((t1 -. t0) *. 1_000_000_000.0);
    minor_words = 0.0; major_words = 0.0; promoted_words = 0.0;
    top_heap_words = 0; rss_kb = max rss_before rss_after }

let run_curl_concurrent ~url ~insecure ~http2 ~tmp_dir ~concurrency =
  let script = Filename.concat tmp_dir "curl_concurrent.sh" in
  let flags =
    let parts = ref ["-s"; "-o"; "/dev/null"] in
    if insecure then parts := "-k" :: !parts;
    if http2 then parts := "--http2" :: !parts;
    String.concat " " (List.map Filename.quote !parts)
  in
  let script_content =
    Printf.sprintf "#!/bin/bash\nfor i in $(seq 1 %d); do\n  curl %s %s &\ndone\nwait\n"
      concurrency flags (Filename.quote url)
  in
  Util.write_file script script_content;
  let rss_before = Util.rss_kb () in
  let t0 = Unix.gettimeofday () in
  ignore (Sys.command ("bash " ^ Filename.quote script));
  let t1 = Unix.gettimeofday () in
  let rss_after = Util.rss_kb () in
  { scenario = ""; client = "curl"; iteration = 1;
    duration_ns = Int64.of_float ((t1 -. t0) *. 1_000_000_000.0);
    minor_words = 0.0; major_words = 0.0; promoted_words = 0.0;
    top_heap_words = 0; rss_kb = max rss_before rss_after }

let run_curl_post ~url ~insecure ~http2 ~tmp_dir ~body_bytes =
  let body_path = Filename.concat tmp_dir "post_body" in
  Util.write_file body_path body_bytes;
  let rss_before = Util.rss_kb () in
  let t0 = Unix.gettimeofday () in
  let _result =
    Curl.run ~url ~method_:"POST" ~headers:[("Content-Type", "text/plain")]
      ~body_path:(Some body_path) ~insecure ~http2 ~tmp_dir
  in
  let t1 = Unix.gettimeofday () in
  let rss_after = Util.rss_kb () in
  { scenario = ""; client = "curl"; iteration = 0;
    duration_ns = Int64.of_float ((t1 -. t0) *. 1_000_000_000.0);
    minor_words = 0.0; major_words = 0.0; promoted_words = 0.0;
    top_heap_words = 0; rss_kb = max rss_before rss_after }

let run_get_scenario ~env ~name ~protocol ~transport ~port ~cert_dir ~iterations ~path ~tmp_dir =
  let url =
    let scheme = match transport with Plain -> "http" | TLS -> "https" in
    Printf.sprintf "%s://127.0.0.1:%d%s" scheme port path
  in
  let eta_iters = ref [] in
  let curl_iters = ref [] in
  Eio.Switch.run (fun sw ->
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
	      let client = make_eta_client ~env ~sw ~protocol ~transport ~cert_dir in
	      for i = 1 to iterations do
	        let r = run_eta_get ~rt ~client ~url in
	        eta_iters := { r with scenario = name; iteration = i } :: !eta_iters
	      done;
	      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client)));
  for i = 1 to iterations do
    let r = run_curl_get ~url ~insecure:(transport = TLS) ~http2:(protocol = H2) ~tmp_dir in
    curl_iters := { r with scenario = name; iteration = i } :: !curl_iters
  done;
  List.rev !eta_iters @ List.rev !curl_iters

let run_post_scenario ~env ~name ~protocol ~transport ~port ~cert_dir ~iterations ~path ~tmp_dir ~body_bytes =
  let url =
    let scheme = match transport with Plain -> "http" | TLS -> "https" in
    Printf.sprintf "%s://127.0.0.1:%d%s" scheme port path
  in
  let eta_iters = ref [] in
  let curl_iters = ref [] in
  Eio.Switch.run (fun sw ->
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
	      let client = make_eta_client ~env ~sw ~protocol ~transport ~cert_dir in
	      for i = 1 to iterations do
	        let r = run_eta_post ~rt ~client ~url ~body_bytes in
	        eta_iters := { r with scenario = name; iteration = i } :: !eta_iters
	      done;
	      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client)));
  for i = 1 to iterations do
    let r = run_curl_post ~url ~insecure:(transport = TLS) ~http2:(protocol = H2) ~tmp_dir ~body_bytes in
    curl_iters := { r with scenario = name; iteration = i } :: !curl_iters
  done;
  List.rev !eta_iters @ List.rev !curl_iters

let run_concurrent_scenario ~env ~name ~protocol ~transport ~port ~cert_dir ~concurrency ~path ~tmp_dir =
  let url =
    let scheme = match transport with Plain -> "http" | TLS -> "https" in
    Printf.sprintf "%s://127.0.0.1:%d%s" scheme port path
  in
  let eta_gc_before = Util.gc_stat () in
  let eta_rss_before = Util.rss_kb () in
  let eta_t0 = Unix.gettimeofday () in
  Eio.Switch.run (fun sw ->
      let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
	      let client = make_eta_client ~env ~sw ~protocol ~transport ~cert_dir in
      let fibers =
        List.init concurrency (fun _i ->
            fun () ->
              run_eta_get ~rt ~client ~url |> ignore)
      in
	      Eio.Fiber.List.iter (fun f -> f ()) fibers;
	      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client)));
  let eta_t1 = Unix.gettimeofday () in
  let eta_rss_after = Util.rss_kb () in
  let eta_gc_after = Util.gc_stat () in
  let eta_duration_ns = Int64.of_float ((eta_t1 -. eta_t0) *. 1_000_000_000.0) in
  let curl = run_curl_concurrent ~url ~insecure:(transport = TLS) ~http2:(protocol = H2) ~tmp_dir ~concurrency in
  [ { scenario = name; client = "eta"; iteration = 1;
      duration_ns = eta_duration_ns;
      minor_words = minor_words eta_gc_after -. minor_words eta_gc_before;
      major_words = major_words eta_gc_after -. major_words eta_gc_before;
      promoted_words = promoted_words eta_gc_after -. promoted_words eta_gc_before;
      top_heap_words = top_heap_words eta_gc_after;
      rss_kb = max eta_rss_before eta_rss_after };
    { curl with scenario = name; iteration = 1 } ]

let bench_against_server ~env ~kind ~protocol ~transport ~results_dir =
  let temp_dir = Filename.concat results_dir
      (Printf.sprintf "bench_%s_%s_%s"
         (match kind with Nginx -> "nginx" | Caddy -> "caddy")
         (match protocol with H1 -> "h1" | H2 -> "h2")
         (match transport with Plain -> "plain" | TLS -> "tls")) in
  Util.mkdir_p temp_dir;
  ignore (Fixtures.generate ~dir:temp_dir);
  let port = Util.random_port () in
  let cert_dir =
    match transport with
    | TLS ->
        (match Certs.prepare ~temp_dir with
         | Ok d -> Some d
         | Error e -> failwith ("cert generation failed: " ^ e))
    | Plain -> None
  in
  let cert_dir_str = Option.value ~default:"" cert_dir in
  let pid_path =
    match kind with
    | Nginx -> Nginx.start ~port ~temp_dir ~cert_dir:cert_dir_str ~protocol ~transport
    | Caddy -> Caddy.start ~port ~temp_dir ~cert_dir:cert_dir_str ~protocol ~transport
  in
  match pid_path with
  | Error e ->
      Printf.eprintf "Bench server start failed: %s\n%!" e;
      []
  | Ok pid_path ->
      let all = ref [] in
      (try
	         all := run_get_scenario ~env ~name:"small_get" ~protocol ~transport ~port
	             ~cert_dir:cert_dir_str ~iterations:3 ~path:"/static/1k.bin" ~tmp_dir:temp_dir @ !all;
	         all := run_get_scenario ~env ~name:"medium_get" ~protocol ~transport ~port
	             ~cert_dir:cert_dir_str ~iterations:3 ~path:"/static/1m.bin" ~tmp_dir:temp_dir @ !all;
       with exn ->
         Printf.eprintf "Bench GET scenario failed: %s\n%!" (Printexc.to_string exn));
      (match kind with
       | Nginx -> ignore (Nginx.stop pid_path)
       | Caddy -> ignore (Caddy.stop pid_path));
      !all

let bench_post_against_caddy ~env ~protocol ~transport ~results_dir =
  let temp_dir = Filename.concat results_dir
      (Printf.sprintf "bench_caddy_%s_%s_post"
         (match protocol with H1 -> "h1" | H2 -> "h2")
         (match transport with Plain -> "plain" | TLS -> "tls")) in
  Util.mkdir_p temp_dir;
  ignore (Fixtures.generate ~dir:temp_dir);
  let port = Util.random_port () in
  let cert_dir =
    match transport with
    | TLS ->
        (match Certs.prepare ~temp_dir with
         | Ok d -> Some d
         | Error e -> failwith ("cert generation failed: " ^ e))
    | Plain -> None
  in
  let cert_dir_str = Option.value ~default:"" cert_dir in
  let pid_path =
    Caddy.start ~port ~temp_dir ~cert_dir:cert_dir_str ~protocol ~transport
  in
  match pid_path with
  | Error e ->
      Printf.eprintf "Bench Caddy start failed: %s\n%!" e;
      []
  | Ok pid_path ->
      let all = ref [] in
      let body_1m = String.make (1024 * 1024) 'x' in
      (try
	         all := run_post_scenario ~env ~name:"post_chunked_1m" ~protocol ~transport ~port
	             ~cert_dir:cert_dir_str ~iterations:3 ~path:"/echo" ~tmp_dir:temp_dir ~body_bytes:body_1m @ !all;
       with exn ->
         Printf.eprintf "Bench POST scenario failed: %s\n%!" (Printexc.to_string exn));
      ignore (Caddy.stop pid_path);
      !all

let bench_concurrent_against_server ~env ~kind ~protocol ~transport ~results_dir =
  let temp_dir = Filename.concat results_dir
      (Printf.sprintf "bench_concurrent_%s_%s_%s"
         (match kind with Nginx -> "nginx" | Caddy -> "caddy")
         (match protocol with H1 -> "h1" | H2 -> "h2")
         (match transport with Plain -> "plain" | TLS -> "tls")) in
  Util.mkdir_p temp_dir;
  ignore (Fixtures.generate ~dir:temp_dir);
  let port = Util.random_port () in
  let cert_dir =
    match transport with
    | TLS ->
        (match Certs.prepare ~temp_dir with
         | Ok d -> Some d
         | Error e -> failwith ("cert generation failed: " ^ e))
    | Plain -> None
  in
  let cert_dir_str = Option.value ~default:"" cert_dir in
  let pid_path =
    match kind with
    | Nginx -> Nginx.start ~port ~temp_dir ~cert_dir:cert_dir_str ~protocol ~transport
    | Caddy -> Caddy.start ~port ~temp_dir ~cert_dir:cert_dir_str ~protocol ~transport
  in
  match pid_path with
  | Error e ->
      Printf.eprintf "Bench concurrent server start failed: %s\n%!" e;
      []
  | Ok pid_path ->
      let all = ref [] in
      (try
	         all := run_concurrent_scenario ~env ~name:"concurrent_20_h2" ~protocol ~transport ~port
	             ~cert_dir:cert_dir_str ~concurrency:20 ~path:"/static/1k.bin" ~tmp_dir:temp_dir @ !all;
       with exn ->
         Printf.eprintf "Bench concurrent scenario failed: %s\n%!" (Printexc.to_string exn));
      (match kind with
       | Nginx -> ignore (Nginx.stop pid_path)
       | Caddy -> ignore (Caddy.stop pid_path));
      !all

let run_all ~env ~results_dir =
  let all = ref [] in
  all := bench_against_server ~env ~kind:Nginx ~protocol:H1 ~transport:Plain ~results_dir @ !all;
  all := bench_against_server ~env ~kind:Nginx ~protocol:H2 ~transport:TLS ~results_dir @ !all;
  all := bench_post_against_caddy ~env ~protocol:H2 ~transport:TLS ~results_dir @ !all;
  !all
