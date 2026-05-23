(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Eta_http_error.Error
module Stream = Stream

type context = {
  protocol : Error.protocol;
  method_ : string;
  uri : string;
}

let default_context = { protocol = Error.Unknown; method_ = "*"; uri = "*" }
let default_max_decoded_bytes = 256 * 1024 * 1024

let make_error context codec message =
  Error.make ~protocol:context.protocol ~method_:context.method_ ~uri:context.uri
    (Decode_error { codec; message })

let bigstring_of_bytes bytes =
  Bigstringaf.of_string ~off:0 ~len:(Bytes.length bytes)
    (Bytes.unsafe_to_string bytes)

let bytes_of_bigstring bs ~len =
  Bytes.of_string (Bigstringaf.substring bs ~off:0 ~len)

let gzip_decode ?(max_decoded_bytes = default_max_decoded_bytes)
    ?(context = default_context) input =
  if max_decoded_bytes < 0 then
    invalid_arg
      "Eta_http.Body.Transducer.gzip_decode: max_decoded_bytes must be >= 0";
  let output = De.bigstring_create Gz.io_buffer_size in
  let output_len = De.bigstring_length output in
  let decoder = ref (Gz.Inf.decoder `Manual ~o:output) in
  let current_src = ref None in
  let decoded = ref 0 in
  let input_eof = ref false in
  let ended = ref false in
  let pending_end = ref None in
  let record_decoded len =
    let next = !decoded + len in
    if next < !decoded || next > max_decoded_bytes then
      Error
        (make_error context "gzip"
           (Printf.sprintf "decoded body exceeds %d bytes" max_decoded_bytes))
    else (
      decoded := next;
      Ok ())
  in
  let flush_chunk d =
    let len = output_len - Gz.Inf.dst_rem d in
    if len = 0 then Ok None
    else
      match record_decoded len with
      | Error error -> Error error
      | Ok () ->
          let chunk = bytes_of_bigstring output ~len in
          Ok (Some (Stream.Chunk chunk))
  in
  let feed_bigstring d bs off len =
    current_src := Some (bs, off, len);
    decoder := Gz.Inf.src d bs off len
  in
  let feed_bytes d chunk =
    let bs = bigstring_of_bytes chunk in
    feed_bigstring d bs 0 (Bytes.length chunk)
  in
  let rec read_next () =
    if !ended then Effect.pure Stream.End
    else
      match !pending_end with
      | Some d ->
          pending_end := None;
          continue_after_member d
      | None -> (
      match Gz.Inf.decode !decoder with
      | `Malformed message -> Effect.fail (make_error context "gzip" message)
      | `Flush next -> (
          match flush_chunk next with
          | Error error -> Effect.fail error
          | Ok (Some chunk) ->
              decoder := Gz.Inf.flush next;
              Effect.pure chunk
          | Ok None ->
              decoder := Gz.Inf.flush next;
              read_next ())
      | `End next -> (
          match flush_chunk next with
          | Error error -> Effect.fail error
          | Ok (Some chunk) ->
              pending_end := Some (Gz.Inf.flush next);
              Effect.pure chunk
          | Ok None -> continue_after_member next)
      | `Await next ->
          current_src := None;
          if !input_eof then
            Effect.fail (make_error context "gzip" "truncated gzip stream")
          else
            Stream.read input
            |> Effect.bind (function
                 | Some chunk ->
                     feed_bytes next chunk;
                     read_next ()
                 | None ->
                     input_eof := true;
                     decoder := Gz.Inf.src next De.bigstring_empty 0 0;
                     read_next ()))
  and continue_after_member d =
    let rem = Gz.Inf.src_rem d in
    if rem > 0 then
      match !current_src with
      | Some (bs, off, len) ->
          let consumed = len - rem in
          feed_bigstring (Gz.Inf.reset d) bs (off + consumed) rem;
          read_next ()
      | None ->
          Effect.fail
            (make_error context "gzip" "gzip decoder lost remaining input")
    else if !input_eof then (
      ended := true;
      Effect.pure Stream.End)
    else
      Stream.read input
      |> Effect.bind (function
           | Some chunk ->
               feed_bytes (Gz.Inf.reset d) chunk;
               read_next ()
           | None ->
               input_eof := true;
               ended := true;
               Effect.pure Stream.End)
  in
  Stream.of_reader ~release:(fun () -> Stream.discard input) read_next

let gzip_encode ?(level = 4) ?(context = default_context) input =
  if level < 0 || level > 9 then
    invalid_arg "Eta_http.Body.Transducer.gzip_encode: level must be 0..9";
  let output = De.bigstring_create Gz.io_buffer_size in
  let output_len = De.bigstring_length output in
  let q = De.Queue.create 0x10000 in
  let w = De.Lz77.make_window ~bits:15 in
  let encoder =
    ref
      (Gz.Def.encoder `Manual `Manual ~mtime:0l Gz.Unix ~q ~w ~level
       |> fun enc -> Gz.Def.dst enc output 0 output_len)
  in
  let sent_eof = ref false in
  let ended = ref false in
  let flush_chunk next last =
    let len = output_len - Gz.Def.dst_rem next in
    if len = 0 then None
    else
      let chunk = bytes_of_bigstring output ~len in
      Some (if last then Stream.Last chunk else Stream.Chunk chunk)
  in
  let rec read_next () =
    if !ended then Effect.pure Stream.End
    else
      match Gz.Def.encode !encoder with
      | `Flush next -> (
          match flush_chunk next false with
          | Some chunk ->
              encoder := Gz.Def.dst next output 0 output_len;
              Effect.pure chunk
          | None ->
              encoder := Gz.Def.dst next output 0 output_len;
              read_next ())
      | `End next -> (
          ended := true;
          match flush_chunk next true with
          | Some chunk -> Effect.pure chunk
          | None -> Effect.pure Stream.End)
      | `Await next ->
          if !sent_eof then
            Effect.fail
              (make_error context "gzip" "gzip encoder requested input after EOF")
          else
            Stream.read input
            |> Effect.bind (function
                 | Some chunk ->
                     encoder :=
                       Gz.Def.src next (bigstring_of_bytes chunk) 0
                         (Bytes.length chunk);
                     read_next ()
                 | None ->
                     sent_eof := true;
                     encoder := Gz.Def.src next De.bigstring_empty 0 0;
                     read_next ())
  in
  Stream.of_reader ~release:(fun () -> Stream.discard input) read_next
