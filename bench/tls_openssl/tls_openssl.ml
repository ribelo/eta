let url = "https://example.com/"

let run_handshake () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addrs = Eio.Net.getaddrinfo_stream net "example.com" ~service:"443" in
  let addr = List.hd addrs in
  let flow = (Eio.Net.connect ~sw net addr :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t) in
  let config = Eta_http.Tls.Config.default_client
    ~peer_name:(Domain_name.host_exn (Domain_name.of_string_exn "example.com")) () in
  let _tls = Eta_http.Tls.Eio.client_of_flow config
    ~host:(Domain_name.host_exn (Domain_name.of_string_exn "example.com")) flow in
  ()

let run_get () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let client = Eta_http.Client.make_h1 ~sw ~net () in
  let request = Eta_http.Request.make "GET" url in
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  match Eta.Runtime.run rt (Eta_http.request client request) with
  | Eta.Exit.Ok response ->
      let body_result =
        Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
      in
      (match body_result with
      | Eta.Exit.Ok body -> ignore body
      | Eta.Exit.Error _ -> ());
      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client))
  | Eta.Exit.Error cause ->
      Format.eprintf "TLS GET bench error: %a@."
        (Eta.Cause.pp Eta_http.Error.pp) cause;
      exit 1

let () =
  let opts = Bench_lib.parse_args () in
  Bench_lib.run opts [
    { name = "tls_openssl.handshake_example";
      run = run_handshake;
      samples = None };
    { name = "tls_openssl.get_example";
      run = run_get;
      samples = None };
  ]
