open Eta_http_testsuite

let () =
  Eio_main.run @@ fun env ->
  let temp_dir = Filename.temp_dir "eta_h1_tls_debug" "" in
  let cert_dir =
    match Certs.prepare ~temp_dir with
    | Ok dir -> dir
    | Error e -> failwith ("cert generation failed: " ^ e)
  in
  let port = Util.random_port () in
  Eio.Switch.run @@ fun sw ->
  match
    Eta_server.start ~sw ~env ~port ~temp_dir ~cert_dir ~protocol:Types.H1
      ~transport:Types.TLS ()
  with
  | Error e -> failwith ("server start failed: " ^ e)
  | Ok _server ->
      Printf.printf "server listening on https://127.0.0.1:%d/\n%!" port;
      Eio.Time.sleep (Eio.Stdenv.clock env) 300.0
