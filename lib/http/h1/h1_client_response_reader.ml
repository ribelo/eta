(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta
open H1_client_types

module Body = Stream
module Chunked = Chunked
module Error = Error
module Header = Header

let is_chunked headers =
  match Header.get "transfer-encoding" headers with
  | Some value -> String_helpers.contains_token_ascii_ci value "chunked"
  | None -> false

let response_has_body request status =
  (match Method.of_string request.method_ with `HEAD -> false | _ -> true)
  && (status < 100 || status >= 200)
  && status <> 204 && status <> 304

let connection_close_requested headers =
  match Header.get "connection" headers with
  | None -> false
  | Some value -> String_helpers.contains_token_ascii_ci value "close"

let max_header_bytes = 32 * 1024
let default_max_response_body_bytes = Body.default_max_bytes
let max_response_headers = 256
let response_chunk_size = 64 * 1024

let read_more ?host_eio flow read_buffer buffer used =
  if used >= Bytes.length buffer then
    Error (Parse.Header_section_too_large { limit = max_header_bytes })
  else
    let len = Bytes.length buffer - used in
    try
      let read =
        match host_eio with
        | None -> Eio.Flow.single_read flow (Cstruct.sub read_buffer used len)
        | Some host_eio ->
            let module Flow = (val Host_eio.flow host_eio : EIO_FLOW) in
            Flow.single_read flow (Cstruct.sub read_buffer used len)
      in
      if read = 0 then Error Parse.Partial
      else (
        Cstruct.blit_to_bytes read_buffer used buffer used read;
        Ok (used + read))
    with End_of_file -> Error Parse.Partial

type response_head = {
  status : int;
  headers : Header.t;
  content_length : int option;
  initial : bytes;
}

let read_response_head ?host_eio ?(initial = Bytes.empty) flow request =
  let buffer = Bytes.create max_header_bytes in
  let initial_len = Bytes.length initial in
  if initial_len > max_header_bytes then
    Error
      (H1_client_errors.parse_error request
         (Parse.Header_section_too_large { limit = max_header_bytes }))
  else (
    if initial_len > 0 then Bytes.blit initial 0 buffer 0 initial_len;
    let read_buffer = Cstruct.create max_header_bytes in
    let raw_headers = Parse.create_raw_headers max_response_headers in
    let raw = Parse.create_raw_response () in
    let rec loop used =
      match
        Parse.parse_raw buffer ~len:used ~max_header_bytes ~headers:raw_headers
          raw
      with
      | code when code = Parse.raw_ok || code = Parse.raw_body_truncated ->
          let body_off = Parse.raw_body_off raw in
          let available = max 0 (used - body_off) in
          let initial = Bytes.create available in
          if available > 0 then Bytes.blit buffer body_off initial 0 available;
          Ok
            {
              status = Parse.raw_status raw;
              headers =
                Header.unsafe_of_list
                  (Parse.raw_headers_to_list buffer raw_headers raw);
              content_length = Parse.raw_content_length raw;
              initial;
            }
      | code when code = Parse.raw_partial -> (
          match read_more ?host_eio flow read_buffer buffer used with
          | Ok used -> loop used
          | Error Parse.Partial ->
              Error (H1_client_errors.io_closed request Http_response)
          | Error error -> Error (H1_client_errors.parse_error request error))
      | code ->
          Error
            (H1_client_errors.parse_error request
               (Parse.raw_error buffer raw ~max_header_bytes code))
    in
    loop initial_len)

type body_source = {
  request : request;
  initial : bytes;
  mutable off : int;
  scratch : Cstruct.t;
  read_into : Cstruct.t -> int;
}

let make_body_source ?host_eio flow request initial =
  {
    request;
    initial;
    off = 0;
    scratch = Cstruct.create response_chunk_size;
    read_into =
      (fun buffer ->
        match host_eio with
        | None -> Eio.Flow.single_read flow buffer
        | Some host_eio ->
            let module Flow = (val Host_eio.flow host_eio : EIO_FLOW) in
            Flow.single_read flow buffer);
  }

let source_pending source = Bytes.length source.initial - source.off

let source_take_pending source n =
  let take = min n (source_pending source) in
  let chunk = Bytes.sub source.initial source.off take in
  source.off <- source.off + take;
  chunk

let mark_clean_response_end source clean =
  (* Eta's HTTP/1.1 pool serializes requests; it does not pipeline. Bytes left
     after a complete response body are therefore not a valid future response
     cache for this client. Keep [clean] false so pooled release fences the
     connection instead of letting unsolicited bytes poison the next request. *)
  if source_pending source = 0 then clean := true

let source_read_some source max_len =
  Effect.sync (fun () ->
      if max_len <= 0 then None
      else if source_pending source > 0 then
        Some (source_take_pending source max_len)
      else
        let len = min max_len (Cstruct.length source.scratch) in
        try
          let read = source.read_into (Cstruct.sub source.scratch 0 len) in
          if read = 0 then None
          else
            let chunk = Bytes.create read in
            Cstruct.blit_to_bytes source.scratch 0 chunk 0 read;
            Some chunk
        with End_of_file -> None)

let source_read_exact source n =
  let out = Bytes.create n in
  let rec loop off remaining =
    if remaining = 0 then Effect.pure out
    else
      source_read_some source remaining
      |> Effect.bind (function
           | Some chunk ->
               let len = Bytes.length chunk in
               Bytes.blit chunk 0 out off len;
               loop (off + len) (remaining - len)
           | None ->
               Effect.fail
                 (H1_client_errors.io_closed source.request Http_response))
  in
  loop 0 n

let source_read_line source ~limit =
  let buffer = Buffer.create 32 in
  let rec loop count previous_cr =
    if count > limit then
      Effect.fail
        (H1_client_errors.protocol_violation source.request "chunked"
           (Printf.sprintf "chunk line exceeds %d bytes" limit))
    else
      source_read_exact source 1
      |> Effect.bind (fun byte ->
             let c = Bytes.get byte 0 in
             if previous_cr && Char.equal c '\n' then (
               let len = Buffer.length buffer in
               let line = Buffer.contents buffer in
               Effect.pure (String.sub line 0 (len - 1)))
             else (
               Buffer.add_char buffer c;
               loop (count + 1) (Char.equal c '\r')))
  in
  loop 0 false

let release_body ~release ~on_unread_body clean =
  if !clean then release ()
  else on_unread_body () |> Effect.bind release

let fixed_body ~release ~on_unread_body source length =
  let remaining = ref length in
  let clean = ref false in
  if length = 0 then mark_clean_response_end source clean;
  let read_next () =
    if !remaining = 0 then Effect.pure Body.End
    else
      source_read_some source (min response_chunk_size !remaining)
      |> Effect.bind (function
           | None ->
               Effect.fail
                 (H1_client_errors.io_closed source.request Http_response)
           | Some chunk ->
               let len = Bytes.length chunk in
               remaining := !remaining - len;
               if !remaining = 0 then (
                 mark_clean_response_end source clean;
                 Effect.pure (Body.Last chunk))
               else Effect.pure (Body.Chunk chunk))
  in
  Body.of_reader ~release:(fun () -> release_body ~release ~on_unread_body clean) read_next

let close_delimited_body ~max_response_body_bytes ~release ~on_unread_body source =
  let total = ref 0 in
  let clean = ref false in
  let read_next () =
    source_read_some source response_chunk_size
    |> Effect.bind (function
         | None ->
             clean := true;
             Effect.pure Body.End
         | Some chunk ->
             let length = !total + Bytes.length chunk in
             if length < !total || length > max_response_body_bytes then
               Effect.fail
                 (H1_client_errors.body_too_large source.request
                    ~limit:max_response_body_bytes ~length)
             else (
               total := length;
               Effect.pure (Body.Chunk chunk)))
  in
  Body.of_reader ~release:(fun () -> release_body ~release ~on_unread_body clean) read_next

let chunked_body ~max_response_body_bytes ~release ~on_unread_body request source =
  let context =
    { Chunked.protocol = Error.H1; method_ = request.method_; uri = H1_client_errors.uri request }
  in
  let reader =
    {
      Chunked.read_exact = source_read_exact source;
      read_line = source_read_line source;
    }
  in
  let decoder =
    Chunked.create ~max_decoded_bytes:max_response_body_bytes ~context ~reader ()
  in
  let read_next () =
    Chunked.read decoder
    |> Effect.map (function None -> Body.End | Some chunk -> Body.Chunk chunk)
  in
  let clean = ref false in
  let read_next () =
    read_next ()
    |> Effect.map (function
         | Body.End ->
             mark_clean_response_end source clean;
             Body.End
         | chunk -> chunk)
  in
  ( Body.of_reader
      ~release:(fun () -> release_body ~release ~on_unread_body clean)
      read_next,
    fun () -> Effect.pure (Chunked.trailers decoder) )

let response_body ?host_eio ~max_response_body_bytes ~release
    ?(on_unread_body = fun () -> Effect.unit) flow request
    (head : response_head) =
  let source = make_body_source ?host_eio flow request head.initial in
  if not (response_has_body request head.status) then
    let clean = ref false in
    mark_clean_response_end source clean;
    ( Body.of_reader
        ~release:(fun () -> release_body ~release ~on_unread_body clean)
        (fun () -> Effect.pure Body.End),
      fun () -> Effect.pure Header.empty )
  else if is_chunked head.headers then
    chunked_body ~max_response_body_bytes ~release ~on_unread_body request source
  else
    match head.content_length with
    | Some length ->
        if length > max_response_body_bytes then
          let clean = ref false in
          let body =
            Body.of_reader
              ~release:(fun () -> release_body ~release ~on_unread_body clean)
              (fun () ->
                Effect.fail
                  (H1_client_errors.body_too_large request
                     ~limit:max_response_body_bytes ~length))
          in
          (body, fun () -> Effect.pure Header.empty)
        else (
          fixed_body ~release ~on_unread_body source length,
          fun () -> Effect.pure Header.empty)
    | None ->
        ( close_delimited_body ~max_response_body_bytes ~release ~on_unread_body
            source,
          fun () -> Effect.pure Header.empty )
