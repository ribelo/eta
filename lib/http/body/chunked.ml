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
  read_exact : (int -> (bytes, Error.t) Effect.t);
  read_line : (limit:int -> (string, Error.t) Effect.t);
}

type t = {
  context : context;
  reader : reader;
  max_decoded_bytes : int;
  max_trailer_bytes : int;
  max_trailers : int;
  mutable decoded_bytes : int;
  mutable done_ : bool;
  mutable trailers : Header.t;
}

let default_line_limit = 8 * 1024
let default_max_decoded_bytes = Stream.default_max_bytes
let default_max_trailer_bytes = 8 * 1024
let default_max_trailers = 64

let create ?(max_decoded_bytes = default_max_decoded_bytes)
    ?(max_trailer_bytes = default_max_trailer_bytes)
    ?(max_trailers = default_max_trailers) ~context ~reader () =
  if max_decoded_bytes < 0 then
    invalid_arg "Eta_http.Body.Chunked.create: max_decoded_bytes must be >= 0";
  if max_trailer_bytes < 0 then
    invalid_arg "Eta_http.Body.Chunked.create: max_trailer_bytes must be >= 0";
  if max_trailers < 0 then
    invalid_arg "Eta_http.Body.Chunked.create: max_trailers must be >= 0";
  {
    context;
    reader;
    max_decoded_bytes;
    max_trailer_bytes;
    max_trailers;
    decoded_bytes = 0;
    done_ = false;
    trailers = Header.empty;
  }

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

let[@zero_alloc] chunk_size_stop line =
  match String.index_opt line ';' with
  | None -> String.length line
  | Some index -> index

let invalid_chunk_size line start stop =
  Error ("invalid chunk size " ^ String.escaped (String.sub line start (stop - start)))

let parse_size line =
  let raw_stop = chunk_size_stop line in
  if raw_stop = 0 then Error "empty chunk size"
  else if not (is_hex (String.unsafe_get line 0)) then
    invalid_chunk_size line 0 raw_stop
  else
    let rec loop index acc =
      if index = raw_stop then Ok acc
      else
        let c = String.unsafe_get line index in
        if not (is_hex c) then
          invalid_chunk_size line 0 raw_stop
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

let invalid_trailer_message = function
  | Error.Header_invalid { reason } -> "invalid trailer header: " ^ reason
  | kind -> "invalid trailer header: " ^ Error.kind_name kind

(* RFC 7230 6919/7230 4.1.2: framing, routing, and authentication fields must
   not appear in trailers, since a recipient merging them into the header set
   could be misled about body length/framing or connection handling. *)
let forbidden_trailer_name name =
  match String.lowercase_ascii (String.trim name) with
  | "connection" | "keep-alive" | "proxy-authenticate" | "proxy-authorization"
  | "te" | "trailer" | "transfer-encoding" | "upgrade" | "host"
  | "content-length" ->
      true
  | _ -> false

let store_trailers t trailers =
  match Header.of_list (List.rev trailers) with
  | Ok trailers -> (
      match
        List.find_opt (fun (name, _) -> forbidden_trailer_name name) trailers
      with
      | Some (name, _) ->
          Effect.fail (decode_error t ("forbidden trailer field: " ^ name))
      | None ->
          t.trailers <- trailers;
          t.done_ <- true;
          Effect.pure None)
  | Error kind -> Effect.fail (decode_error t (invalid_trailer_message kind))

let trailer_section_too_large t length =
  decode_error t
    (Printf.sprintf "trailer section too large: limit=%d length=%d"
       t.max_trailer_bytes length)

let too_many_trailers t count =
  decode_error t
    (Printf.sprintf "too many trailers: limit=%d count=%d" t.max_trailers count)

let rec read_trailers t acc bytes count =
  t.reader.read_line ~limit:default_line_limit
  |> Effect.bind (fun line ->
         let next_bytes = bytes + String.length line + 2 in
         if next_bytes < bytes || next_bytes > t.max_trailer_bytes then
           Effect.fail (trailer_section_too_large t next_bytes)
         else if String.equal line "" then store_trailers t acc
         else if count >= t.max_trailers then
           Effect.fail (too_many_trailers t (count + 1))
         else
           match parse_trailer line with
           | Error message -> Effect.fail (decode_error t message)
           | Ok trailer -> read_trailers t (trailer :: acc) next_bytes (count + 1))

let read t =
  if t.done_ then Effect.pure None
  else
    t.reader.read_line ~limit:default_line_limit
    |> Effect.bind (fun line ->
           match parse_size line with
           | Error message -> Effect.fail (decode_error t message)
           | Ok 0 -> read_trailers t [] 0 0
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
  let count = ref 1 in
  let value = ref (value lsr 4) in
  while !value > 0 do
    incr count;
    value := !value lsr 4
  done;
  !count

let chunk_header_bytes length =
  let digits = hex_digit_count length in
  let out = Bytes.create (digits + 2) in
  let value = ref length in
  for index = digits - 1 downto 0 do
    Bytes.unsafe_set out index
      (Eta.String_helpers.lower_hex_digit (!value land 0xf));
    value := !value lsr 4
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
  (match Header.validate trailers with
  | None -> ()
  | Some _ ->
      invalid_arg
        "Eta_http.Body.Chunked.encode_last_chunk: invalid trailer header");
  (match
     List.find_opt (fun (name, _) -> forbidden_trailer_name name) trailers
   with
  | None -> ()
  | Some (name, _) ->
      invalid_arg
        ("Eta_http.Body.Chunked.encode_last_chunk: forbidden trailer field "
       ^ name));
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
