(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module H2_proto = Eta_http.H2

let response_headers response =
  response.H2_proto.Connection.Client.headers
  |> List.filter (fun (name, _) ->
         String.length name = 0 || not (Char.equal name.[0] ':'))

let response_has_body request status =
  (match Method.of_string request.Request.method_ with `HEAD -> false | _ -> true)
  && (status < 100 || status >= 200)
  && status <> 204 && status <> 304

let trailer_result request =
  let promise, resolver = Eio.Promise.create () in
  let resolver_ref = ref (Some resolver) in
  let resolve value =
    match !resolver_ref with
    | None -> ()
    | Some resolver ->
        resolver_ref := None;
        Eio.Promise.resolve resolver value
  in
  let resolve_headers headers =
    match Security.validate_headers headers with
    | Some kind -> resolve (Error (H2_client_errors.error request kind))
    | None -> resolve (Ok headers)
  in
  let resolve_empty () = resolve (Ok Header.empty) in
  let resolve_error error = resolve (Error error) in
  let trailers () =
    Eta.Effect.sync (fun () -> Eio.Promise.await promise)
    |> Eta.Effect.bind (function
         | Ok headers -> Eta.Effect.pure headers
         | Error error -> Eta.Effect.fail error)
  in
  (trailers, resolve_headers, resolve_empty, resolve_error)

let informational_status status = status >= 100 && status < 200 && status <> 101

let close_no_body ~mux ~unregister ~resolve_empty_trailers stream body =
  resolve_empty_trailers ();
  H2_proto.Body.Reader.close body;
  Multiplexer.mark_complete mux stream;
  ignore (Multiplexer.release mux stream);
  unregister ()

let response_body ~request ~mux ~body_error ~body_wake ~unregister
    ~resolve_empty_trailers ~resolve_trailer_error stream body =
  let body, wake =
    Multiplexer.body_stream_async
      ~closed_error:(H2_client_errors.closed request Http_response)
      ~poll_error:(fun () -> !body_error)
      ~on_eof:(fun () ->
        unregister ();
        resolve_empty_trailers ())
      ~on_release:(fun _decision ->
        unregister ();
        resolve_trailer_error (H2_client_errors.closed request Http_response);
        Eta.Effect.unit)
      mux stream body
  in
  body_wake := wake;
  body
