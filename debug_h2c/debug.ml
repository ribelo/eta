open Eta_http_testsuite

let () =
  Eio_main.run @@ fun env ->
  let temp_dir = Filename.temp_dir "eta_h2c_debug" "" in
  let port = Util.random_port () in
  Eio.Switch.run @@ fun sw ->
  match
    Eta_server.start ~sw ~env ~port ~temp_dir ~protocol:Types.H2
      ~transport:Types.Plain ()
  with
  | Error e -> failwith ("server start failed: " ^ e)
  | Ok _server ->
      Printf.printf "server listening on http://127.0.0.1:%d/\n%!" port;
      Eio.Time.sleep (Eio.Stdenv.clock env) 300.0
