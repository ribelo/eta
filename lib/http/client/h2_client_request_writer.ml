(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module Body_source = Source
module H2_proto = H2

let skip_header name =
  match Header.normalize_name name with
  | "connection" | "host" | "keep-alive" | "proxy-connection"
  | "transfer-encoding" | "upgrade" ->
      true
  | normalized -> String.length normalized > 0 && Char.equal normalized.[0] ':'

let headers request url =
  match Header.validate request.Request.headers with
  | Some kind -> Error (H2_client_errors.error request kind)
  | None ->
      let user_headers =
        request.Request.headers
        |> List.filter_map (fun (name, value) ->
               if skip_header name then None
               else Some (Header.normalize_name name, value))
      in
      let has_content_length =
        List.exists
          (fun (name, _) ->
            String.equal (Header.normalize_name name) "content-length")
          user_headers
      in
      let content_length =
        if has_content_length then None
        else
          match request.body with
          | Empty | Stream _ -> None
          | Fixed chunks ->
              Some
                (chunks
                 |> List.fold_left
                      (fun total chunk -> total + Bytes.length chunk)
                      0)
          | Rewindable_stream { length; _ } -> length
      in
      let user_headers =
        match content_length with
        | None -> user_headers
        | Some length -> ("content-length", string_of_int length) :: user_headers
      in
      Ok (H2_proto.Headers.of_list ((":authority", Url.authority url) :: user_headers))

let method_ = function
  | `GET -> `GET
  | `HEAD -> `HEAD
  | `POST -> `POST
  | `PUT -> `PUT
  | `DELETE -> `DELETE
  | `CONNECT -> `CONNECT
  | `OPTIONS -> `OPTIONS
  | `TRACE -> `TRACE
  | `PATCH -> `Other "PATCH"
  | `Other method_ -> `Other method_

let request_of_request request url =
  match headers request url with
  | Error _ as error -> error
  | Ok headers ->
      Ok
        (H2_proto.Request.create
           ~scheme:(Url.scheme_to_string (Url.scheme url))
           ~headers
           (method_ (Request.method_value request))
           (Url.origin_form url))

let flush_body_writer writer =
  let promise, resolver = Eio.Promise.create () in
  H2_proto.Body.Writer.flush writer (fun result ->
      ignore (Eio.Promise.try_resolve resolver result));
  Eio.Promise.await promise

(* Streaming uploads must await ocaml-h2's flush callback before pulling the next
   chunk; it is the body writer's only transport-progress/backpressure signal. *)
let write_chunk_result writer chunk =
  let chunk = Bytes.to_string chunk in
  let rec loop off =
    if off >= String.length chunk then Eta.Effect.pure `Written
    else
      let len = min 16_384 (String.length chunk - off) in
      Eta.Effect.sync (fun () ->
          H2_proto.Body.Writer.write_string writer (String.sub chunk off len);
          flush_body_writer writer)
      |> Eta.Effect.bind (function
           | `Written -> loop (off + len)
           | `Closed -> Eta.Effect.pure `Closed)
  in
  loop 0

let write_chunk writer chunk =
  write_chunk_result writer chunk |> Eta.Effect.map (fun _ -> ())

let write_fixed_body_sync writer chunks =
  let write_chunk chunk =
    let s = Bytes.unsafe_to_string chunk in
    let len = Bytes.length chunk in
    let rec loop off =
      if off < len then (
        let write_len = min 65_536 (len - off) in
        H2_proto.Body.Writer.write_string writer s ~off ~len:write_len;
        match flush_body_writer writer with
        | `Written -> loop (off + write_len)
        | `Closed -> ())
    in
    loop 0
  in
  List.iter write_chunk chunks;
  H2_proto.Body.Writer.close writer

let rec write_stream writer body =
  Body.read body
  |> Eta.Effect.bind (function
       | None -> Eta.Effect.unit
       | Some chunk ->
           write_chunk_result writer chunk
           |> Eta.Effect.bind (function
                | `Written -> write_stream writer body
                | `Closed -> Eta.Effect.unit))

let write_body writer request_body upload =
  match upload with
  | Some { Body_source.stream; _ } -> write_stream writer stream
  | None -> (
      match request_body with
      | Request.Empty -> Eta.Effect.unit
      | Fixed chunks -> chunks |> List.map (write_chunk writer) |> Eta.Effect.concat
      | Stream _ | Rewindable_stream _ -> Eta.Effect.unit)

let close_request_body writer =
  Eta.Effect.sync (fun () -> try H2_proto.Body.Writer.close writer with _ -> ())
