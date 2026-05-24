(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Eta_http_error.Error
module Header = Eta_http_core.Header

type context = {
  protocol : Error.protocol;
  method_ : string;
  uri : string;
}

type reader = {
  read_exact : int -> (bytes, Error.t) Effect.t;
  read_line : limit:int -> (string, Error.t) Effect.t;
}

type t = {
  context : context;
  reader : reader;
  max_decoded_bytes : int;
  mutable decoded_bytes : int;
  mutable done_ : bool;
  mutable trailers : Header.t;
}

let default_line_limit = 8 * 1024
let default_max_decoded_bytes = Stream.default_max_bytes

let create ?(max_decoded_bytes = default_max_decoded_bytes) ~context ~reader () =
  if max_decoded_bytes < 0 then
    invalid_arg "Eta_http.Body.Chunked.create: max_decoded_bytes must be >= 0";
  { context; reader; max_decoded_bytes; decoded_bytes = 0; done_ = false; trailers = Header.empty }

let decode_error t message =
  Error.make ~protocol:t.context.protocol ~method_:t.context.method_
    ~uri:t.context.uri (Decode_error { codec = "chunked"; message })

let body_too_large t length =
  Error.make ~protocol:t.context.protocol ~method_:t.context.method_
    ~uri:t.context.uri
    (Body_too_large { limit = t.max_decoded_bytes; length })

let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let hex_value = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | 'a' .. 'f' as c -> 10 + Char.code c - Char.code 'a'
  | 'A' .. 'F' as c -> 10 + Char.code c - Char.code 'A'
  | _ -> -1

let trim_chunk_size line =
  match String.index_opt line ';' with
  | None -> String.trim line
  | Some index -> String.trim (String.sub line 0 index)

let parse_size line =
  let value = trim_chunk_size line in
  let len = String.length value in
  if len = 0 then Error "empty chunk size"
  else
    let rec loop index acc =
      if index = len then Ok acc
      else
        let c = String.unsafe_get value index in
        if not (is_hex c) then
          Error ("invalid chunk size " ^ String.escaped value)
        else
          let digit = hex_value c in
          if acc > (max_int - digit) / 16 then Error "chunk size overflow"
          else loop (index + 1) ((acc * 16) + digit)
    in
    loop 0 0

let parse_trailer line =
  match String.index_opt line ':' with
  | None -> Error ("invalid trailer " ^ String.escaped line)
  | Some 0 -> Error ("invalid trailer " ^ String.escaped line)
  | Some index ->
      let name = String.sub line 0 index in
      let value =
        String.sub line (index + 1) (String.length line - index - 1)
        |> String.trim
      in
      Ok (name, value)

let rec read_trailers t acc =
  t.reader.read_line ~limit:default_line_limit
  |> Effect.bind (fun line ->
         if String.equal line "" then (
           t.trailers <- Header.unsafe_of_list (List.rev acc);
           t.done_ <- true;
           Effect.pure None)
         else
           match parse_trailer line with
           | Error message -> Effect.fail (decode_error t message)
           | Ok trailer -> read_trailers t (trailer :: acc))

let read t =
  if t.done_ then Effect.pure None
  else
    t.reader.read_line ~limit:default_line_limit
    |> Effect.bind (fun line ->
           match parse_size line with
           | Error message -> Effect.fail (decode_error t message)
           | Ok 0 -> read_trailers t []
           | Ok size ->
               let next_total = t.decoded_bytes + size in
               if next_total < t.decoded_bytes || next_total > t.max_decoded_bytes then
                 Effect.fail (body_too_large t next_total)
               else
                 t.reader.read_exact size
                 |> Effect.bind (fun chunk ->
                        t.reader.read_exact 2
                        |> Effect.bind (fun crlf ->
                               if not (Bytes.equal crlf (Bytes.of_string "\r\n")) then
                                 Effect.fail (decode_error t "chunk data missing CRLF")
                               else (
                                 t.decoded_bytes <- next_total;
                                 Effect.pure (Some chunk)))))

let trailers t = t.trailers

let hex_of_int n = Printf.sprintf "%x" n

let encode_chunk chunk =
  if Bytes.length chunk = 0 then []
  else
    [
      Bytes.of_string (hex_of_int (Bytes.length chunk) ^ "\r\n");
      Bytes.copy chunk;
      Bytes.of_string "\r\n";
    ]

let encode_last_chunk ?(trailers = Header.empty) () =
  let buffer = Buffer.create 32 in
  Buffer.add_string buffer "0\r\n";
  List.iter
    (fun (name, value) ->
      Buffer.add_string buffer name;
      Buffer.add_string buffer ": ";
      Buffer.add_string buffer value;
      Buffer.add_string buffer "\r\n")
    (List.rev trailers);
  Buffer.add_string buffer "\r\n";
  Bytes.of_string (Buffer.contents buffer)
