(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module Body_source = Source
module H2_proto = Eta_http.H2

let skip_header name =
  match Header.normalize_name name with
  | "connection" | "host" | "keep-alive" | "proxy-connection"
  | "transfer-encoding" | "upgrade" ->
      true
  | normalized -> String.length normalized > 0 && Char.equal normalized.[0] ':'

let headers request =
  match Header.validate request.Request.headers with
  | Some kind -> Error (H2_client_errors.error request kind)
  | None ->
      let user_headers, has_content_length =
        let rec loop acc has_content_length = function
          | [] -> (List.rev acc, has_content_length)
          | (name, value) :: rest ->
              if skip_header name then loop acc has_content_length rest
              else
                let normalized = Header.normalize_name name in
                loop ((normalized, value) :: acc)
                  (has_content_length
                  || String.equal normalized "content-length")
                  rest
        in
        loop [] false request.Request.headers
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
      Ok user_headers

let method_ = function
  | `GET -> "GET"
  | `HEAD -> "HEAD"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `DELETE -> "DELETE"
  | `CONNECT -> "CONNECT"
  | `OPTIONS -> "OPTIONS"
  | `TRACE -> "TRACE"
  | `PATCH -> "PATCH"
  | `Other method_ -> method_

let request_of_request request url =
  match headers request with
  | Error _ as error -> error
  | Ok headers ->
      Ok
        {
          H2_proto.Connection.Client.meth = method_ (Request.method_value request);
          scheme = Some (Url.scheme_to_string (Url.scheme url));
          authority = Some (Url.authority url);
          path = Url.origin_form url;
          headers;
        }

let flush_body_writer writer =
  let promise, resolver = Eio.Promise.create () in
  H2_proto.Body.Writer.flush writer (fun () ->
      ignore (Eio.Promise.try_resolve resolver ()));
  Eio.Promise.await promise

(* Streaming uploads must await the body writer's flush callback before pulling
   the next chunk; it is the transport-progress/backpressure signal. *)
let write_chunk_result writer chunk =
  let chunk = Bytes.to_string chunk in
  let rec loop off =
    if off >= String.length chunk then Eta.Effect.pure `Written
    else
      let len = min 16_384 (String.length chunk - off) in
      Eta.Effect.sync (fun () ->
          let bytes = Bytes.of_string (String.sub chunk off len) in
          match H2_proto.Body.Writer.write_bytes writer bytes ~off:0 ~len with
          | Error _ -> `Closed
          | Ok () ->
              flush_body_writer writer;
              `Written)
      |> Eta.Effect.bind (function
           | `Written -> loop (off + len)
           | `Closed -> Eta.Effect.pure `Closed)
  in
  loop 0

let write_chunk writer chunk =
  write_chunk_result writer chunk |> Eta.Effect.map (fun _ -> ())

let rec write_chunks writer = function
  | [] -> Eta.Effect.unit
  | chunk :: rest ->
      write_chunk writer chunk |> Eta.Effect.bind (fun () -> write_chunks writer rest)

let write_fixed_body_sync writer chunks =
  let write_chunk chunk =
    let s = Bytes.to_string chunk in
    let len = Bytes.length chunk in
    let rec loop off =
      if off < len then (
        let write_len = min 65_536 (len - off) in
        let bytes = Bytes.of_string (String.sub s off write_len) in
        match H2_proto.Body.Writer.write_bytes writer bytes ~off:0 ~len:write_len with
        | Error _ -> ()
        | Ok () ->
            flush_body_writer writer;
            loop (off + write_len))
    in
    loop 0
  in
  let rec write_chunks = function
    | [] -> ()
    | chunk :: rest ->
        write_chunk chunk;
        write_chunks rest
  in
  write_chunks chunks;
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
      | Fixed chunks -> write_chunks writer chunks
      | Stream _ | Rewindable_stream _ -> Eta.Effect.unit)

let close_request_body writer =
  Eta.Effect.sync (fun () -> try H2_proto.Body.Writer.close writer with _ -> ())
