(** Nginx server lifecycle and config templating. *)

let ( let* ) = Result.bind
let quote = Filename.quote

let config ~port ~temp_dir ~cert_dir ~protocol ~transport =
  let temp_dir = Util.absolute_path temp_dir in
  let cert_dir =
    if cert_dir = "" then cert_dir else Util.absolute_path cert_dir
  in
  let ssl_block =
    match transport with
    | Types.Plain -> ""
    | Types.TLS ->
        Printf.sprintf
          "    ssl_certificate %s;\n    ssl_certificate_key %s;\n"
          (Filename.concat cert_dir "server.pem")
          (Filename.concat cert_dir "server.key")
  in
  let listen_directive =
    match protocol, transport with
    | Types.H1, Types.Plain -> Printf.sprintf "listen %d;" port
    | Types.H2, Types.Plain -> Printf.sprintf "listen %d http2;" port
    | Types.H1, Types.TLS -> Printf.sprintf "listen %d ssl;" port
    | Types.H2, Types.TLS -> Printf.sprintf "listen %d ssl http2;" port
  in
  Printf.sprintf
{|worker_processes 1;
daemon off;
error_log stderr;
pid %s;
events { worker_connections 1024; }
http {
  access_log off;
  server {
    %s
    server_name localhost;
%s
    root %s;
    location = / { return 200 ""; }
    location = /user/123 { return 200 "123"; }
    location = /user { return 200 ""; }
    location /healthz { return 200 "ok\n"; }
    location /echo {
      add_header Content-Type text/plain;
      return 200 $request_body;
    }
    location /reflect {
      add_header Content-Type text/plain;
      return 200 $request_body;
    }
    location /static/ { alias %s/; }
    location /redirect301 { return 301 /healthz; }
    location /redirect302 { return 302 /healthz; }
    location /redirect307 { return 307 /healthz; }
    location /redirect308 { return 308 /healthz; }
    location /status204 { return 204; }
    location /status206 {
      add_header Content-Type text/plain;
      return 206 "partial";
    }
    location /status400 { return 400; }
    location /status401 { return 401; }
    location /status413 { return 413; }
    location /status429 { return 429; }
    location /status500 { return 500; }
    location /status502 { return 502; }
    location /status503 { return 503; }
    location /status504 { return 504; }
    location /trailer {
      add_header Trailer X-Trailer;
      add_trailer X-Trailer nginx-trailer;
      return 200 "body-with-trailer";
    }
  }
}|}
    (Filename.concat temp_dir "nginx.pid")
    listen_directive
    ssl_block
    temp_dir
    (Filename.concat temp_dir "")

let write_config ~port ~temp_dir ~cert_dir ~protocol ~transport =
  let config = config ~port ~temp_dir ~cert_dir ~protocol ~transport in
  let path = Filename.concat temp_dir "nginx.conf" in
  Util.write_file path config;
  path

let wait_ready ~port ~transport ~deadline_ms =
  let start = Util.now_ms () in
  let scheme, tls_flag =
    match transport with
    | Types.Plain -> ("http", "")
    | Types.TLS -> ("https", "-k ")
  in
  let rec poll () =
    let now = Util.now_ms () in
    if now -. start > deadline_ms then Error "nginx readiness poll timed out"
    else
      match
        Util.run_cmd_out
          (Printf.sprintf "curl -s %s-o /dev/null -w %%{http_code} %s://127.0.0.1:%d/healthz"
             tls_flag scheme port)
      with
      | Ok ["200"] -> Ok ()
      | _ ->
          Unix.sleepf 0.05;
          poll ()
  in
  poll ()

let start ~port ~temp_dir ~cert_dir ~protocol ~transport =
  let config_path = write_config ~port ~temp_dir ~cert_dir ~protocol ~transport in
  let pid_path = Filename.concat temp_dir "nginx.pid" in
  let config_path_abs = Util.absolute_path config_path in
  let temp_dir_abs = Util.absolute_path temp_dir in
  let* () =
    Util.run_cmd
      (Printf.sprintf "nginx -c %s -p %s >%s/nginx.log 2>&1 &"
         (quote config_path_abs)
         (quote temp_dir_abs)
         (quote temp_dir))
  in
  (* wait for pid file to appear *)
  let start = Util.now_ms () in
  let rec wait_pid () =
    if Sys.file_exists pid_path then Ok ()
    else if Util.now_ms () -. start > 2000.0 then Error "nginx pid file never appeared"
    else (Unix.sleepf 0.05; wait_pid ())
  in
  let* () = wait_pid () in
  let* () = wait_ready ~port ~transport ~deadline_ms:5000.0 in
  Ok pid_path

let stop pid_path =
  let pid_path = Util.absolute_path pid_path in
  if Sys.file_exists pid_path then
    let* pid_lines = Util.run_cmd_out (Printf.sprintf "cat %s" (quote pid_path)) in
    match pid_lines with
    | pid :: _ ->
        let pid = int_of_string (String.trim pid) in
        (try Unix.kill pid Sys.sigterm with _ -> ());
        let rec wait attempts =
          if attempts <= 0 then Ok ()
          else
            try
              Unix.kill pid 0;
              Unix.sleepf 0.05;
              wait (attempts - 1)
            with _ -> Ok ()
        in
        wait 40
    | [] -> Ok ()
  else Ok ()
