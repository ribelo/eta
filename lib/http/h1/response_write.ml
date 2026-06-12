(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type body =
  | No_body
  | Fixed of bytes list
  | Suppressed_stream of Server_response.Body.stream
  | Stream_fixed of Server_response.Body.stream
  | Stream_chunked of Server_response.Body.stream
  | Stream_close_delimited of Server_response.Body.stream

type prepared = {
  head : string;
  body : body;
  close : bool;
}

type error =
  | Caller_framing_header of string
  | Caller_hop_by_hop_header of string
  | Trailer_without_chunked_body
  | Invalid_trailer_name of string
  | Forbidden_trailer_name of string
  | Body_length_overflow
  | Streaming_body

let pp_error fmt = function
  | Caller_framing_header name ->
      Format.fprintf fmt "caller supplied response framing header %S" name
  | Caller_hop_by_hop_header name ->
      Format.fprintf fmt "caller supplied hop-by-hop response header %S" name
  | Trailer_without_chunked_body ->
      Format.pp_print_string fmt
        "Trailer header requires HTTP/1.1 chunked response framing"
  | Invalid_trailer_name name ->
      Format.fprintf fmt "invalid response trailer name %S" name
  | Forbidden_trailer_name name ->
      Format.fprintf fmt "forbidden response trailer name %S" name
  | Body_length_overflow ->
      Format.pp_print_string fmt "response body length overflows int"
  | Streaming_body ->
      Format.pp_print_string fmt "response body is streaming"

let error_to_string error = Format.asprintf "%a" pp_error error

let wire_version = function
  | Version.H1_0 -> "HTTP/1.0"
  | H1_1 -> "HTTP/1.1"
  | H2 -> invalid_arg "Eta_http.H1.Response_write: HTTP/2 is not H1"

let reason_phrase = function
  | 100 -> "Continue"
  | 101 -> "Switching Protocols"
  | 102 -> "Processing"
  | 103 -> "Early Hints"
  | 200 -> "OK"
  | 201 -> "Created"
  | 202 -> "Accepted"
  | 203 -> "Non-Authoritative Information"
  | 204 -> "No Content"
  | 205 -> "Reset Content"
  | 206 -> "Partial Content"
  | 300 -> "Multiple Choices"
  | 301 -> "Moved Permanently"
  | 302 -> "Found"
  | 303 -> "See Other"
  | 304 -> "Not Modified"
  | 307 -> "Temporary Redirect"
  | 308 -> "Permanent Redirect"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 405 -> "Method Not Allowed"
  | 408 -> "Request Timeout"
  | 409 -> "Conflict"
  | 410 -> "Gone"
  | 411 -> "Length Required"
  | 413 -> "Payload Too Large"
  | 414 -> "URI Too Long"
  | 415 -> "Unsupported Media Type"
  | 417 -> "Expectation Failed"
  | 418 -> "I'm a Teapot"
  | 421 -> "Misdirected Request"
  | 422 -> "Unprocessable Content"
  | 425 -> "Too Early"
  | 426 -> "Upgrade Required"
  | 429 -> "Too Many Requests"
  | 431 -> "Request Header Fields Too Large"
  | 500 -> "Internal Server Error"
  | 501 -> "Not Implemented"
  | 502 -> "Bad Gateway"
  | 503 -> "Service Unavailable"
  | 504 -> "Gateway Timeout"
  | 505 -> "HTTP Version Not Supported"
  | _ -> ""

let add_header_line buffer (name, value) =
  Buffer.add_string buffer name;
  Buffer.add_string buffer ": ";
  Buffer.add_string buffer value;
  Buffer.add_string buffer "\r\n"

let has_header name headers =
  Option.is_some (Header.get name headers)

let caller_framing_header headers =
  if has_header "content-length" headers then Some "Content-Length"
  else if has_header "transfer-encoding" headers then Some "Transfer-Encoding"
  else None

let caller_hop_by_hop_header headers =
  let candidates =
    [
      ("connection", "Connection");
      ("keep-alive", "Keep-Alive");
      ("proxy-connection", "Proxy-Connection");
      ("te", "TE");
      ("upgrade", "Upgrade");
    ]
  in
  List.find_map
    (fun (name, canonical) ->
      if has_header name headers then Some canonical else None)
    candidates

let bodyless_response ~request_method status =
  (match Method.of_string request_method with `HEAD -> true | _ -> false)
  || Status.forbids_response_body status

let strict_no_body_status = Status.forbids_response_body

let add_chunks_length total chunk =
  let len = Bytes.length chunk in
  if total > max_int - len then Error Body_length_overflow else Ok (total + len)

let fixed_body_length chunks =
  List.fold_left
    (fun acc chunk ->
      match acc with
      | Error _ as error -> error
      | Ok total -> add_chunks_length total chunk)
    (Ok 0) chunks

let body_decision ~version ~request_method response =
  let status = Server_response.status response in
  let body = Server_response.body response in
  let bodyless = bodyless_response ~request_method status in
  let strict_no_body = strict_no_body_status status in
  match (bodyless, strict_no_body, body) with
  | true, true, Server_response.Body.Stream stream ->
      Ok (Suppressed_stream stream, None, false)
  | true, true, _ -> Ok (No_body, None, false)
  | true, false, Server_response.Body.Empty -> Ok (No_body, Some 0, false)
  | true, false, Server_response.Body.Fixed chunks ->
      fixed_body_length chunks |> Result.map (fun length -> (No_body, Some length, false))
  | true, false, Server_response.Body.Stream stream ->
      Ok (Suppressed_stream stream, stream.length, false)
  | false, _, Server_response.Body.Empty -> Ok (No_body, Some 0, false)
  | false, _, Server_response.Body.Fixed chunks ->
      fixed_body_length chunks
      |> Result.map (fun length -> (Fixed chunks, Some length, false))
  | false, _, Server_response.Body.Stream ({ length = Some length; _ } as stream) ->
      Ok (Stream_fixed stream, Some length, false)
  | false, _, Server_response.Body.Stream stream -> (
      match version with
      | Version.H1_1 -> Ok (Stream_chunked stream, None, false)
      | H1_0 -> Ok (Stream_close_delimited stream, None, true)
      | H2 -> invalid_arg "Eta_http.H1.Response_write: HTTP/2 is not H1")

let trailer_names headers =
  Header.get_all "trailer" headers
  |> List.concat_map (String.split_on_char ',')

let validate_trailer_name name =
  let name = Eta.String_helpers.trim name in
  if Option.is_some (Header.validate_name name) then
    Error (Invalid_trailer_name name)
  else if Chunked.forbidden_trailer_name name then
    Error (Forbidden_trailer_name name)
  else Ok ()

let validate_trailer_header headers body =
  match trailer_names headers with
  | [] -> Ok ()
  | names -> (
      match body with
      | Stream_chunked _ ->
          let rec loop = function
            | [] -> Ok ()
            | name :: rest -> (
                match validate_trailer_name name with
                | Ok () -> loop rest
                | Error _ as error -> error)
          in
          loop names
      | No_body | Fixed _ | Suppressed_stream _ | Stream_fixed _
      | Stream_close_delimited _ ->
          Error Trailer_without_chunked_body)

let prepare ?(connection_close = false) ~version ~request_method response =
  let headers = Server_response.headers response in
  match caller_framing_header headers with
  | Some name -> Error (Caller_framing_header name)
  | None -> (
      match caller_hop_by_hop_header headers with
      | Some name -> Error (Caller_hop_by_hop_header name)
      | None -> (
          match body_decision ~version ~request_method response with
          | Error _ as error -> error
          | Ok (body, content_length, close_for_body) -> (
              match validate_trailer_header headers body with
              | Error _ as error -> error
              | Ok () ->
                  let close = connection_close || close_for_body in
                  let status = Server_response.status response in
                  let buffer = Buffer.create 256 in
                  Buffer.add_string buffer (wire_version version);
                  Buffer.add_char buffer ' ';
                  Buffer.add_string buffer (string_of_int status);
                  Buffer.add_char buffer ' ';
                  Buffer.add_string buffer (reason_phrase status);
                  Buffer.add_string buffer "\r\n";
                  List.iter (add_header_line buffer) headers;
                  if close then add_header_line buffer ("Connection", "close");
                  (match content_length with
                  | Some length ->
                      add_header_line buffer
                        ("Content-Length", string_of_int length)
                  | None -> (
                      match body with
                      | Stream_chunked _ ->
                          add_header_line buffer
                            ("Transfer-Encoding", "chunked")
                      | No_body | Fixed _ | Stream_fixed _
                      | Suppressed_stream _ | Stream_close_delimited _ ->
                          ()));
                  Buffer.add_string buffer "\r\n";
                  Ok { head = Buffer.contents buffer; body; close })))

let to_string ?connection_close ~version ~request_method response =
  match prepare ?connection_close ~version ~request_method response with
  | Error _ as error -> error
  | Ok { head; body = No_body; _ } -> Ok head
  | Ok { head; body = Fixed chunks; _ } ->
      let buffer = Buffer.create (String.length head) in
      Buffer.add_string buffer head;
      List.iter (fun chunk -> Buffer.add_bytes buffer chunk) chunks;
      Ok (Buffer.contents buffer)
  | Ok
      {
        body =
          Suppressed_stream _ | Stream_fixed _ | Stream_chunked _
          | Stream_close_delimited _;
        _;
      } ->
      Error Streaming_body

let encode_chunk = Chunked.encode_chunk
let encode_last_chunk = Chunked.encode_last_chunk
