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
          let module Flow = (val Host_eio.flow host_eio : EIO_FLOW) in
          Flow.write flow [ Cstruct.of_bytes bytes ])

let transfer_encoding_chunked headers =
  match Header.get "transfer-encoding" headers with
  | None -> false
  | Some value -> String_helpers.contains_token_ascii_ci value "chunked"

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

let stream_headers (request : request) length =
  let has_content_length = Option.is_some (Header.get "content-length" request.headers) in
  let has_transfer_encoding =
    Option.is_some (Header.get "transfer-encoding" request.headers)
  in
  match (length, has_content_length, has_transfer_encoding) with
  | Some length, false, false ->
      Header.unsafe_add "Content-Length" (string_of_int length) request.headers
  | None, false, false ->
      Header.unsafe_add "Transfer-Encoding" "chunked" request.headers
  | _ -> request.headers

let write_to_host_flow host_eio request flow ~headers ~body =
  match
    Write.to_string ~method_:request.method_ ~url:request.url ~headers ~body
  with
  | Error _ as error -> error
  | Ok bytes -> (
      try
        let module Flow = (val Host_eio.flow host_eio : EIO_FLOW) in
        Flow.write flow [ Cstruct.of_string bytes ];
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> Error (H1_client_errors.io_closed request Http_request))

let write_headers_effect ?host_eio request flow ~headers =
  Effect.sync (fun () ->
      try
        match host_eio with
        | None ->
            Write.write_to_flow flow ~method_:request.method_ ~url:request.url
              ~headers ~body:Write.Empty
        | Some host_eio ->
            write_to_host_flow host_eio request flow ~headers ~body:Write.Empty
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
        let headers = stream_headers request length in
        write_headers_effect ?host_eio request flow ~headers
        |> Effect.bind (fun () ->
               if transfer_encoding_chunked headers then
                 write_chunked_stream ?host_eio request flow stream
               else write_raw_stream ?host_eio request flow stream))
