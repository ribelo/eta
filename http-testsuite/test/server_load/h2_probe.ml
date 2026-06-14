(* Standalone Eta H2C server probe for autoresearch.
   Starts the testsuite eta H2C server on a fixed port and runs until killed.
   Usage: h2_probe.exe PORT TEMP_DIR *)

let () =
  (try Memtrace.trace_if_requested () with _ -> ());
  let port = int_of_string Sys.argv.(1) in
  let temp_dir = Sys.argv.(2) in
  ignore (Eta_http_testsuite.Fixtures.generate ~dir:temp_dir);
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  match
    Eta_http_testsuite.Eta_server.start ~sw ~env ~port ~temp_dir
      ~protocol:Eta_http_testsuite.Types.H2
      ~transport:Eta_http_testsuite.Types.Plain ()
  with
  | Error e ->
      prerr_endline ("probe start failed: " ^ e);
      exit 1
  | Ok _server ->
      Printf.printf "READY %d\n%!" port;
      (* Block forever; killed by measure.sh. *)
      let forever = Eio.Stdenv.clock env in
      while true do
        Eio.Time.sleep forever 3600.0
      done
