(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module Body_source = Source
module H2_proto = Eta_http_h2

module Errors = H2_client_errors
module Request_writer = H2_client_request_writer
module Response_reader = H2_client_response_reader

let informational_status = Response_reader.informational_status

let request_on_connection connection request url =
  let mux = Connection.mux connection in
  let result, resolver = Eio.Promise.create () in
  let body_error = ref None in
  let response_started = ref false in
  let response_returned = ref false in
  let body_wake = ref (fun () -> ()) in
  let unregister_failure = ref (fun () -> ()) in
  let trailers, resolve_trailers, resolve_empty_trailers, resolve_trailer_error =
    Response_reader.trailer_result request
  in
  let unregister () =
    let f = !unregister_failure in
    unregister_failure := (fun () -> ());
    f ()
  in
  let resolve_result value = ignore (Eio.Promise.try_resolve resolver value) in
  let resolve_error error =
    unregister ();
    resolve_result (Error error)
  in
  let set_body_error error =
    body_error := Some error;
    resolve_trailer_error error;
    !body_wake ()
  in
  unregister_failure :=
    Connection.register_failure_handler connection (fun kind ->
        let error = Errors.error request kind in
        if !response_started then set_body_error error else resolve_error error);
  let note_upload_error error =
    if !response_started then set_body_error error else resolve_error error
  in
  let open_request h2_request =
    Connection.request connection ~tag:0 h2_request
      ~trailers_handler:(fun headers -> resolve_trailers headers)
      ~error_handler:(fun stream error ->
        Multiplexer.mark_remote_reset mux
          (Stream_state.id stream);
        let error =
          Errors.protocol_violation request "stream"
            (Errors.pp_client_error error)
        in
        if !response_started then set_body_error error else resolve_error error)
      ~response_handler:(fun stream response body ->
        let status = response.H2_proto.Connection.Client.status in
        let headers = Response_reader.response_headers response in
        match Security.validate_headers headers with
        | Some kind ->
            H2_proto.Body.Reader.close body;
            ignore (Multiplexer.release mux stream);
            resolve_error (Errors.error request kind)
        | None when Response_reader.informational_status status -> ()
        | None when Response_reader.response_has_body request status ->
            response_started := true;
            let body =
              Response_reader.response_body ~request ~mux ~body_error ~body_wake
                ~unregister ~resolve_empty_trailers ~resolve_trailer_error
                stream body
            in
            let response = Response.make ~status ~headers ~trailers ~body () in
            resolve_result (Ok response)
        | None ->
            response_started := true;
            let response =
              Response.make ~status ~headers ~trailers ~body:(Body.empty ()) ()
            in
            resolve_result (Ok response);
            Response_reader.close_no_body ~mux ~unregister
              ~resolve_empty_trailers stream body)
  in
  let wait_for_response () =
    Eta.Effect.sync (fun () -> Eio.Promise.await result)
    |> Eta.Effect.bind (function
         | Ok response ->
             response_returned := true;
             Eta.Effect.pure response
         | Error error -> Eta.Effect.fail error)
  in
  match Request_writer.request_of_request request url with
  | Error error -> resolve_error error; Eta.Effect.fail error
  | Ok h2_request -> (
  match open_request h2_request with
  | Error (Admission_rejected { limit }) ->
      let error = Errors.error request (Stream_admission_rejected { limit }) in
      resolve_error error;
      Eta.Effect.fail error
  | Error Connection_closed ->
      let error = Errors.closed request Http_request in
      resolve_error error;
      Eta.Effect.fail error
  | Error (Request_failed message) ->
      let error = Errors.protocol_violation request "request" message in
      resolve_error error;
      Eta.Effect.fail error
  | Ok opened ->
      let release_unreturned_request () =
        if !response_returned then Eta.Effect.unit
        else
          Eta.Effect.sync (fun () ->
              unregister ();
              (try H2_proto.Body.Writer.close opened.request_body with _ -> ());
              ignore (Multiplexer.release mux opened.stream))
      in
      Body_source.with_owned_stream (Request.body_source request.body) (fun upload ->
          let write_request =
            Request_writer.write_body opened.request_body request.body upload
            |> Eta.Effect.bind (fun () ->
                   Request_writer.close_request_body opened.request_body)
            |> Eta.Effect.bind_error (fun error ->
                   if not !response_started then resolve_error error;
                   Eta.Effect.fail error)
          in
          let response_or_writer =
            match request.body with
            | Empty ->
                Request_writer.close_request_body opened.request_body
                |> Eta.Effect.bind (fun () -> wait_for_response ())
            | Fixed [] ->
                Request_writer.close_request_body opened.request_body
                |> Eta.Effect.bind (fun () -> wait_for_response ())
            | Fixed chunks ->
                Eta.Effect.sync (fun () ->
                    Connection.fork_daemon connection (fun () ->
                        try
                          Request_writer.write_fixed_body_sync
                            opened.request_body chunks
                        with exn ->
                          let error =
                            Errors.protocol_violation request "request_body"
                              (Printexc.to_string exn)
                          in
                          note_upload_error error))
                |> Eta.Effect.bind (fun () -> wait_for_response ())
            | Stream _ | Rewindable_stream _ ->
                Eta.Effect.race
                  [
                    wait_for_response ();
                    write_request |> Eta.Effect.bind (fun () -> wait_for_response ());
                  ]
          in
          match request.body with
          | Fixed _ -> response_or_writer
          | Empty | Stream _ | Rewindable_stream _ ->
              Eta.Effect.with_scope
                (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
                   ~release:(fun () ->
                     Request_writer.close_request_body opened.request_body)
                |> Eta.Effect.bind (fun () -> response_or_writer)))
      |> fun request_effect ->
      Eta.Effect.with_scope
        (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
           ~release:release_unreturned_request
        |> Eta.Effect.bind (fun () -> request_effect)))
