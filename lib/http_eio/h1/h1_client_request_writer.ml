(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta
open H1_client_types

module Body = Stream
module Body_source = Source
module Chunked = Chunked
module Header = Header
module Write = Write

let write_body = function
  | Empty -> Write.Empty
  | Fixed chunks -> Write.Fixed chunks
  | Stream _ | Rewindable_stream _ -> Write.Empty

let request_body_source = function
  | Empty -> Body_source.Empty
  | Fixed chunks -> Body_source.Fixed chunks
  | Stream body -> Body_source.Stream body
  | Rewindable_stream { length; make } ->
      Body_source.Rewindable_stream { length; make }

let write_sync request f =
  Effect.sync (fun () ->
      try Ok (f ()) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (H1_client_errors.io_closed request Http_request))
  |> Effect.bind (function Ok value -> Effect.pure value | Error error -> Effect.fail error)

let write_bytes_effect ?host_eio request flow bytes =
  write_sync request (fun () ->
      match host_eio with
      | None -> Eio.Flow.copy_string (Bytes.to_string bytes) flow
      | Some host_eio ->
          let module Flow = (val Eta_eio.Host.flow host_eio : EIO_FLOW) in
          Flow.write flow [ Cstruct.of_bytes bytes ])

let write_raw_stream ?host_eio request flow body =
  let rec loop () =
    Body.read body
    |> Effect.bind (function
         | None -> Effect.unit
         | Some chunk ->
             write_bytes_effect ?host_eio request flow chunk |> Effect.bind loop)
  in
  loop ()

let write_chunked_stream ?host_eio request flow body =
  let rec loop () =
    Body.read body
    |> Effect.bind (function
         | None ->
             write_bytes_effect ?host_eio request flow (Chunked.encode_last_chunk ())
         | Some chunk ->
             Chunked.encode_chunk chunk
             |> List.map (write_bytes_effect ?host_eio request flow)
             |> Effect.concat
             |> Effect.bind loop)
  in
  loop ()

let write_to_host_flow host_eio request flow ~headers ~body =
  let buffer = Buffer.create 256 in
  match
    Write.write buffer ~method_:request.method_ ~url:request.url ~headers ~body
  with
  | Error _ as error -> error
  | Ok () -> (
      try
        let module Flow = (val Eta_eio.Host.flow host_eio : EIO_FLOW) in
        Flow.write flow [ Cstruct.of_string (Buffer.contents buffer) ];
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (H1_client_errors.io_closed request Http_request))

let write_stream_headers_to_host_flow host_eio request flow ~headers ~framing =
  let buffer = Buffer.create 256 in
  match
    Write.write_stream_headers buffer ~method_:request.method_ ~url:request.url
      ~headers ~framing
  with
  | Error _ as error -> error
  | Ok () -> (
      try
        let module Flow = (val Eta_eio.Host.flow host_eio : EIO_FLOW) in
        Flow.write flow [ Cstruct.of_string (Buffer.contents buffer) ];
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (H1_client_errors.io_closed request Http_request))

let write_headers_effect ?host_eio request flow ~headers ~framing =
  Effect.sync (fun () ->
      try
        match host_eio with
        | None ->
            let buffer = Buffer.create 512 in
            (match
               Write.write_stream_headers buffer ~method_:request.method_
                 ~url:request.url ~headers ~framing
             with
            | Error _ as error -> error
            | Ok () ->
                Eio.Flow.copy_string (Buffer.contents buffer) flow;
                Ok ())
        | Some host_eio ->
            write_stream_headers_to_host_flow host_eio request flow ~headers
              ~framing
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (H1_client_errors.io_closed request Http_request))
  |> Effect.bind (function Ok () -> Effect.unit | Error error -> Effect.fail error)

let write_request ?host_eio flow (request : request) =
  Body_source.with_owned_stream (request_body_source request.body) (function
    | None ->
        Effect.sync (fun () ->
            try
              match host_eio with
              | None ->
                  Write.write_to_flow flow ~method_:request.method_ ~url:request.url
                    ~headers:request.headers ~body:(write_body request.body)
              | Some host_eio ->
                  write_to_host_flow host_eio request flow ~headers:request.headers
                    ~body:(write_body request.body)
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | _ -> Error (H1_client_errors.io_closed request Http_request))
        |> Effect.bind (function
             | Ok () -> Effect.unit
             | Error error -> Effect.fail error)
    | Some { length; stream } ->
        (* Validate framing for streamed bodies before writing any headers; the
           owned stream is released by [with_owned_stream] on failure. *)
        let framing_error =
          if
            Option.is_none length
            && Option.is_some (Header.get "content-length" request.headers)
          then
            Some
              (Error.Header_invalid
                 {
                   reason =
                     "Content-Length is not allowed with an unknown-length \
                      streamed request body";
                 })
          else None
        in
        (match framing_error with
        | Some kind -> Effect.fail (H1_client_errors.make_error request kind)
        | None ->
            let framing =
              match length with
              | Some length -> Write.Fixed_length length
              | None -> Write.Chunked
            in
            write_headers_effect ?host_eio request flow ~headers:request.headers
              ~framing
            |> Effect.bind (fun () ->
                   match framing with
                   | Write.Chunked ->
                       write_chunked_stream ?host_eio request flow stream
                   | Write.Fixed_length _ ->
                       write_raw_stream ?host_eio request flow stream)))
