(* Scratch-only S2 smoke through the public eta-http ALPN dispatch path. *)

let url = "https://api.honeycomb.io/v1/auth"

let authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let run_request rt client =
  let request =
    Eta_http.Request.make
      ~headers:[ ("User-Agent", "eta-http-s2-honeycomb-h2") ]
      "GET" url
  in
  let timeout_error =
    Eta_http.Error.make ~method_:"GET" ~uri:url
      (Total_request_timeout { timeout_ms = Some 15_000 })
  in
  let effect =
    Eta_http.request client request
    |> Eta.Effect.bind (fun (response : Eta_http.Response.t) ->
           Eta_http.Body.Stream.read_all response.body
           |> Eta.Effect.bind (fun body ->
                  Eta_http.Client.stats client
                  |> Eta.Effect.map (fun (stats : Eta_http.Client.stats) ->
                         ( response.status,
                           Bytes.length body,
                           Eta_http.Client.protocol_to_string stats.protocol ))))
    |> Eta.Effect.timeout_as (Eta.Duration.seconds 15) ~on_timeout:timeout_error
  in
  Eta.Runtime.run rt effect

let run env =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let client =
    Eta_http.Client.make ~sw ~net:(Eio.Stdenv.net env)
      ~authenticator:(authenticator ()) ()
  in
  match run_request rt client with
  | Eta.Exit.Ok (status, body_bytes, protocol) ->
      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
      Printf.printf
        "eta_http_s2_honeycomb outcome=ok status=%d body_bytes=%d protocol=%s policy=tls12_ecdhe_aead_only\n%!"
        status body_bytes protocol;
      if not (String.equal protocol "h2") then exit 1
  | Eta.Exit.Error cause ->
      ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
      Printf.printf "eta_http_s2_honeycomb outcome=error detail=%S\n%!"
        (Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause);
      exit 1

let () = Eio_main.run run
