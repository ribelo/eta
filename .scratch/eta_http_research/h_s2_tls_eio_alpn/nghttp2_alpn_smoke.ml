let host_name = "nghttp2.org"

let host_exn name =
  match Result.bind (Domain_name.of_string name) Domain_name.host with
  | Ok host -> host
  | Error (`Msg msg) -> failwith msg

let string_of_tls_version = function
  | `TLS_1_0 -> "tls10"
  | `TLS_1_1 -> "tls11"
  | `TLS_1_2 -> "tls12"
  | `TLS_1_3 -> "tls13"

let ca_authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let run env =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock 10.0 (fun () ->
      Ok
        (Eio.Switch.run @@ fun sw ->
         let addr =
           match Eio.Net.getaddrinfo_stream net host_name ~service:"443" with
           | [] -> failwith "no addresses for nghttp2.org:443"
           | addr :: _ -> addr
         in
         let raw_flow = Eio.Net.connect ~sw net addr in
         let tls_flow =
           Tls_eio.client_of_flow
             (Tls.Config.client
                ~authenticator:(ca_authenticator ())
                ~alpn_protocols:[ "h2"; "http/1.1" ]
                ~ciphers:Tls.Config.Ciphers.supported
                ())
             ~host:(host_exn host_name)
             raw_flow
         in
         let epoch =
           match Tls_eio.epoch tls_flow with
           | Ok epoch -> epoch
           | Error () -> failwith "TLS epoch unavailable"
         in
         Eio.Resource.close tls_flow;
         epoch.Tls.Core.alpn_protocol, epoch.Tls.Core.protocol_version))
  with
  | Error `Timeout -> failwith "nghttp2.org TLS ALPN smoke timed out"
  | Ok (selected, version) ->
    if selected <> Some "h2" then
      failwith
        (Printf.sprintf
           "expected nghttp2.org ALPN h2, got %s"
           (Option.value ~default:"<none>" selected));
    Printf.printf
      "h_s2_prod_alpn host=%s selected=%s version=%s\n%!"
      host_name
      (Option.value ~default:"<none>" selected)
      (string_of_tls_version version)

let () = Eio_main.run run
