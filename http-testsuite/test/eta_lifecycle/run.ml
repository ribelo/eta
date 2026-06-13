open Eta_http_testsuite

let fail msg = prerr_endline msg; exit 1

let expect_ok = function
  | Ok value -> value
  | Error error -> fail error

let probe_health ~env ~sw ~port ~protocol ~transport ?cert_dir () =
  match (protocol, transport) with
  | Types.H2, Types.Plain ->
      Eio.Fiber.yield ()
  | _ ->
      let scheme = match transport with Types.Plain -> "http" | TLS -> "https" in
      let url = Printf.sprintf "%s://127.0.0.1:%d/healthz" scheme port in
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let ca_file = Option.map Certs.ca_path cert_dir in
      let client =
        match protocol with
        | Types.H1 ->
            Eta_http_eio.Client.make_h1 ~sw ~net ?ca_file
              ~max_response_body_bytes:1024 ()
        | H2 ->
            Eta_http_eio.Client.make ~sw ~net ~clock ?ca_file
              ~max_response_body_bytes:1024 ()
      in
      let rt = Eta_eio.Runtime.create ~sw ~clock () in
      let request = Eta_http.Request.make "GET" url in
      let effect =
        Eta_http.request client request
        |> Eta.Effect.bind (fun response ->
               Util.body_to_string response.Eta_http.Response.body
               |> Eta.Effect.map (fun body ->
                      (response.Eta_http.Response.status, body)))
        |> Eta.Effect.tap (fun _ -> Eta_http.Client.shutdown client)
      in
      (match Eta.Runtime.run rt effect with
      | Eta.Exit.Ok (200, "ok\n") -> ()
      | Eta.Exit.Ok (status, body) ->
          fail
            (Printf.sprintf "unexpected health response: status=%d body=%S"
               status body)
      | Eta.Exit.Error cause ->
          fail
            (Format.asprintf "eta health probe failed: %a"
               (Eta.Cause.pp Eta_http.Error.pp) cause))

let run_case env protocol transport =
  Eio.Switch.run @@ fun sw ->
  let root =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "eta-testsuite-%06x" (Random.bits ()))
  in
  Util.mkdir_p root;
  ignore (Fixtures.generate ~dir:root);
  let cert_dir =
    match transport with
    | Types.Plain -> None
    | TLS -> Some (Certs.prepare ~temp_dir:root |> expect_ok)
  in
  let port = Util.random_port () in
  let server =
    Eta_server.start ~sw ~env ~port ~temp_dir:root ?cert_dir ~protocol
      ~transport ()
    |> expect_ok
  in
  Fun.protect
    ~finally:(fun () -> ignore (Eta_server.stop server))
    (fun () -> probe_health ~env ~sw ~port ~protocol ~transport ?cert_dir ())

let () =
  Eio_main.run @@ fun env ->
  run_case env Types.H1 Plain;
  run_case env H2 Plain;
  run_case env H1 TLS;
  run_case env H2 TLS
