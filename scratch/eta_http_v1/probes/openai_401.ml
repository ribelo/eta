(* Scratch-only live smoke for S1. Not part of the shipped eta-http package. *)

let fail msg =
  Printf.eprintf "eta_http_openai_401 outcome=error detail=%S\n%!" msg;
  exit 1

let authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> fail msg

let run env =
  Mirage_crypto_rng_eio.run (module Mirage_crypto_rng.Fortuna) env @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let client =
    Eta_http.Client.make_h1 ~sw ~net:(Eio.Stdenv.net env)
      ~authenticator:(authenticator ()) ()
  in
  let request =
    Eta_http.Request.make "GET" "https://api.openai.com/v1/models"
  in
  match Eta.Runtime.run rt (Eta_http.request client request) with
  | Eta.Exit.Error cause ->
      Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause |> fail
  | Eta.Exit.Ok response ->
      let content_length =
        Eta_http.Core.Header.get "content-length" response.headers
        |> Option.value ~default:"<none>"
      in
      let transfer_encoding =
        Eta_http.Core.Header.get "transfer-encoding" response.headers
        |> Option.value ~default:"<none>"
      in
      let body =
        Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
      in
      let body_len =
        match body with
        | Eta.Exit.Ok bytes -> Bytes.length bytes
        | Eta.Exit.Error cause ->
            Format.asprintf "body read failed: %a"
              (Eta.Cause.pp Eta_http.Error.pp)
              cause
            |> fail
      in
      if response.status <> 401 then
        fail (Printf.sprintf "expected status 401, got %d" response.status);
      Printf.printf
        "eta_http_openai_401 outcome=ok status=%d body_bytes=%d content_length=%S transfer_encoding=%S protocol=h1\n%!"
        response.status body_len content_length transfer_encoding

let () = Eio_main.run run
