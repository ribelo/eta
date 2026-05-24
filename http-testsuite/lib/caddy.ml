let ( let* ) = Result.bind

let config_plain_h1 ~port ~temp_dir =
  let temp_dir = Util.absolute_path temp_dir in
  Printf.sprintf
    {|{
  admin off
  persist_config off
}
:%d {
  root * %s
  file_server
  route /healthz {
    respond "ok\n" 200
  }
  route /echo {
    respond "{http.request.body}" 200
  }
  route /reflect {
    respond "{http.request.body}" 200
  }
  route /static/* {
    uri strip_prefix /static
    file_server
  }
  route /redirect301 {
    redir /healthz 301
  }
  route /redirect302 {
    redir /healthz 302
  }
  route /redirect307 {
    redir /healthz 307
  }
  route /redirect308 {
    redir /healthz 308
  }
  route /status204 {
    respond "" 204
  }
  route /status206 {
    respond "partial" 206
  }
  route /status400 {
    respond "" 400
  }
  route /status401 {
    respond "" 401
  }
  route /status413 {
    respond "" 413
  }
  route /status429 {
    respond "" 429
  }
  route /status500 {
    respond "" 500
  }
  route /status502 {
    respond "" 502
  }
  route /status503 {
    respond "" 503
  }
  route /status504 {
    respond "" 504
  }
  route /trailer {
    header +Trailer X-Trailer
    respond "body-with-trailer" 200
  }
}
|}
    port temp_dir

let config_plain_h2 ~port ~temp_dir =
  let temp_dir = Util.absolute_path temp_dir in
  Printf.sprintf
    {|{
  admin off
  persist_config off
  servers {
    protocol {
      allow_h2c
    }
  }
}
:%d {
  root * %s
  file_server
  route /healthz {
    respond "ok\n" 200
  }
  route /echo {
    respond "{http.request.body}" 200
  }
  route /reflect {
    respond "{http.request.body}" 200
  }
  route /static/* {
    uri strip_prefix /static
    file_server
  }
  route /redirect301 {
    redir /healthz 301
  }
  route /redirect302 {
    redir /healthz 302
  }
  route /redirect307 {
    redir /healthz 307
  }
  route /redirect308 {
    redir /healthz 308
  }
  route /status204 {
    respond "" 204
  }
  route /status206 {
    respond "partial" 206
  }
  route /status400 {
    respond "" 400
  }
  route /status401 {
    respond "" 401
  }
  route /status413 {
    respond "" 413
  }
  route /status429 {
    respond "" 429
  }
  route /status500 {
    respond "" 500
  }
  route /status502 {
    respond "" 502
  }
  route /status503 {
    respond "" 503
  }
  route /status504 {
    respond "" 504
  }
  route /trailer {
    header +Trailer X-Trailer
    respond "body-with-trailer" 200
  }
}
|}
    port temp_dir

let config_tls ~port ~temp_dir ~cert_dir =
  let temp_dir = Util.absolute_path temp_dir in
  let cert_dir = Util.absolute_path cert_dir in
  Printf.sprintf
    {|{
  admin off
  persist_config off
  auto_https disable_redirects
}
127.0.0.1:%d {
  tls %s %s
  root * %s
  file_server
  route /healthz {
    respond "ok\n" 200
  }
  route /echo {
    respond "{http.request.body}" 200
  }
  route /reflect {
    respond "{http.request.body}" 200
  }
  route /static/* {
    uri strip_prefix /static
    file_server
  }
  route /redirect301 {
    redir /healthz 301
  }
  route /redirect302 {
    redir /healthz 302
  }
  route /redirect307 {
    redir /healthz 307
  }
  route /redirect308 {
    redir /healthz 308
  }
  route /status204 {
    respond "" 204
  }
  route /status206 {
    respond "partial" 206
  }
  route /status400 {
    respond "" 400
  }
  route /status401 {
    respond "" 401
  }
  route /status413 {
    respond "" 413
  }
  route /status429 {
    respond "" 429
  }
  route /status500 {
    respond "" 500
  }
  route /status502 {
    respond "" 502
  }
  route /status503 {
    respond "" 503
  }
  route /status504 {
    respond "" 504
  }
  route /trailer {
    header +Trailer X-Trailer
    respond "body-with-trailer" 200
  }
}
|}
    port
    (Filename.concat cert_dir "server.pem")
    (Filename.concat cert_dir "server.key")
    temp_dir

let write_config ~port ~temp_dir ~cert_dir ~protocol ~transport =
  let config =
    match protocol, transport with
    | Types.H1, Types.Plain -> config_plain_h1 ~port ~temp_dir
    | Types.H2, Types.Plain -> config_plain_h2 ~port ~temp_dir
    | Types.H1, Types.TLS -> config_tls ~port ~temp_dir ~cert_dir
    | Types.H2, Types.TLS -> config_tls ~port ~temp_dir ~cert_dir
  in
  let path = Filename.concat temp_dir "Caddyfile" in
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
    if now -. start > deadline_ms then Error "caddy readiness poll timed out"
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
  let pid_path = Filename.concat temp_dir "caddy.pid" in
  let config_path_abs = Util.absolute_path config_path in
  let* () =
    Util.run_cmd
      (Printf.sprintf "caddy run --config %s --pidfile %s >%s/caddy.log 2>&1 &"
         (Filename.quote config_path_abs)
         (Filename.quote pid_path)
         (Filename.quote temp_dir))
  in
  let* () = wait_ready ~port ~transport ~deadline_ms:5000.0 in
  Ok pid_path

let stop pid_path =
  let pid_path = Util.absolute_path pid_path in
  if Sys.file_exists pid_path then
    let* pid_lines = Util.run_cmd_out (Printf.sprintf "cat %s" (Filename.quote pid_path)) in
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
