(* Standalone Eta H2-over-TLS server probe for autoresearch.
   Generates a local cert, starts the testsuite eta H2/TLS server on a fixed
   port, and runs until killed.
   Usage: h2_tls_probe.exe PORT TEMP_DIR *)

let () =
  (try Memtrace.trace_if_requested () with _ -> ());
  let port = int_of_string Sys.argv.(1) in
  let temp_dir = Sys.argv.(2) in
  ignore (Eta_http_testsuite.Fixtures.generate ~dir:temp_dir);
  let cert_dir =
    match Eta_http_testsuite.Certs.prepare ~temp_dir with
    | Ok dir -> dir
    | Error e ->
        prerr_endline ("cert prep failed: " ^ e);
        exit 1
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match
    Eta_http_testsuite.Eta_server.start ~sw ~env ~port ~temp_dir ~cert_dir
      ~protocol:Eta_http_testsuite.Types.H2
      ~transport:Eta_http_testsuite.Types.TLS ()
  with
  | Error e ->
      prerr_endline ("probe start failed: " ^ e);
      exit 1
  | Ok _server ->
      Printf.printf "READY %d\n%!" port;
      let clock = Eio.Stdenv.clock env in
      while true do
        Eio.Time.sleep clock 3600.0
      done
