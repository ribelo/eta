(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Error = Error
module Header = Header

type context = {
  protocol : Error.protocol;
  method_ : string;
  uri : string;
}

type reader = {
  read_exact : (int -> (bytes, Error.t) Effect.t) @@ many;
  read_line : (limit:int -> (string, Error.t) Effect.t) @@ many;
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

let[@zero_alloc] is_ows = function
  | ' ' | '\t' | '\r' | '\n' -> true
  | _ -> false

let[@zero_alloc] chunk_size_stop line =
  match String.index_opt line ';' with
  | None -> String.length line
  | Some index -> index

let[@zero_alloc] trim_left_bound line stop =
  let mutable index = 0 in
  while index < stop && is_ows (String.unsafe_get line index) do
    index <- index + 1
  done;
  index

let[@zero_alloc] trim_right_bound line start stop =
  let mutable index = stop in
  while index > start && is_ows (String.unsafe_get line (index - 1)) do
    index <- index - 1
  done;
  index

let invalid_chunk_size line start stop =
  Error ("invalid chunk size " ^ String.escaped (String.sub line start (stop - start)))

let parse_size line =
  let raw_stop = chunk_size_stop line in
  let start = trim_left_bound line raw_stop in
  let stop = trim_right_bound line start raw_stop in
  if start = stop then Error "empty chunk size"
  else
    let rec loop index acc =
      if index = stop then Ok acc
      else
        let c = String.unsafe_get line index in
        if not (is_hex c) then
          invalid_chunk_size line start stop
        else
          let digit = hex_value c in
          if acc > (max_int - digit) / 16 then Error "chunk size overflow"
          else loop (index + 1) ((acc * 16) + digit)
    in
    loop start 0

let parse_trailer line =
  match String.index_opt line ':' with
  | None -> Error ("invalid trailer " ^ String.escaped line)
  | Some 0 -> Error ("invalid trailer " ^ String.escaped line)
  | Some index ->
      let name = String.sub line 0 index in
      let value_start =
        Eta.String_helpers.trim_left line (index + 1) (String.length line)
      in
      let value_stop =
        Eta.String_helpers.trim_right line value_start (String.length line)
      in
      let value = String.sub line value_start (value_stop - value_start) in
      Ok (name, value)

let[@zero_alloc] bytes_is_crlf bytes =
  Bytes.length bytes = 2
  && Char.equal (Bytes.unsafe_get bytes 0) '\r'
  && Char.equal (Bytes.unsafe_get bytes 1) '\n'

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
                               if not (bytes_is_crlf crlf) then
                                 Effect.fail (decode_error t "chunk data missing CRLF")
                               else (
                                 t.decoded_bytes <- next_total;
                                 Effect.pure (Some chunk)))))

let trailers t = t.trailers

let[@zero_alloc] hex_digit_count value =
  let mutable count = 1 in
  let mutable value = value lsr 4 in
  while value > 0 do
    count <- count + 1;
    value <- value lsr 4
  done;
  count

let chunk_header_bytes length =
  let digits = hex_digit_count length in
  let out = Bytes.create (digits + 2) in
  let mutable value = length in
  for index = digits - 1 downto 0 do
    Bytes.unsafe_set out index
      (Eta.String_helpers.lower_hex_digit (value land 0xf));
    value <- value lsr 4
  done;
  Bytes.unsafe_set out digits '\r';
  Bytes.unsafe_set out (digits + 1) '\n';
  out

let crlf_bytes () =
  let out = Bytes.create 2 in
  Bytes.unsafe_set out 0 '\r';
  Bytes.unsafe_set out 1 '\n';
  out

let encode_chunk chunk =
  if Bytes.length chunk = 0 then []
  else
    [
      chunk_header_bytes (Bytes.length chunk);
      Bytes.copy chunk;
      crlf_bytes ();
    ]

let encode_last_chunk ?(trailers = Header.empty) () =
  let buffer = Buffer.create 32 in
  Buffer.add_string buffer "0\r\n";
  let rec add_trailers = function
    | [] -> ()
    | (name, value) :: rest ->
      Buffer.add_string buffer name;
      Buffer.add_string buffer ": ";
      Buffer.add_string buffer value;
      Buffer.add_string buffer "\r\n";
      add_trailers rest
  in
  add_trailers (List.rev trailers);
  Buffer.add_string buffer "\r\n";
  Bytes.of_string (Buffer.contents buffer)
