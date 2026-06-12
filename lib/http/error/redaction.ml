(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = { redacted_headers : string list } [@@unboxed]

let default =
  {
    redacted_headers =
      [
        "authorization";
        "proxy-authorization";
        "www-authenticate";
        "proxy-authenticate";
        "cookie";
        "x-api-key";
        "set-cookie";
      ];
  }

let normalize = Eta.String_helpers.lowercase_ascii_trim

let equal_normalized_name = Eta.String_helpers.trim_equal_ascii_ci

let is_sensitive ?(policy = default) name =
  List.exists
    (fun redacted -> equal_normalized_name redacted name)
    policy.redacted_headers

let headers ?(policy = default) headers =
  List.map
    (fun (name, value) ->
      if is_sensitive ~policy name then (name, "<redacted>") else (name, value))
    headers

let find_scheme_separator uri =
  let len = String.length uri in
  let rec loop index =
    if index + 2 >= len then None
    else if
      Char.equal uri.[index] ':'
      && Char.equal uri.[index + 1] '/'
      && Char.equal uri.[index + 2] '/'
    then Some index
    else loop (index + 1)
  in
  loop 0

let find_authority_end uri start =
  let len = String.length uri in
  let rec loop index =
    if index >= len then len
    else
      match uri.[index] with
      | '/' | '?' | '#' -> index
      | _ -> loop (index + 1)
  in
  loop start

let find_char_between uri start stop needle =
  let rec loop index =
    if index >= stop then None
    else if Char.equal uri.[index] needle then Some index
    else loop (index + 1)
  in
  loop start

let redact_userinfo uri =
  match find_scheme_separator uri with
  | None -> uri
  | Some scheme_end -> (
      let authority_start = scheme_end + 3 in
      let authority_end = find_authority_end uri authority_start in
      match find_char_between uri authority_start authority_end '@' with
      | None -> uri
      | Some userinfo_end ->
          let marker = "<redacted>" in
          let marker_len = String.length marker in
          let prefix_len = authority_start in
          let suffix_len = String.length uri - userinfo_end in
          let out = Bytes.create (prefix_len + marker_len + suffix_len) in
          Bytes.blit_string uri 0 out 0 prefix_len;
          Bytes.blit_string marker 0 out prefix_len marker_len;
          Bytes.blit_string uri userinfo_end out (prefix_len + marker_len)
            suffix_len;
          Bytes.unsafe_to_string out)

let redact_query uri =
  match String.index_opt uri '?' with
  | None -> uri
  | Some query_start ->
      let suffix_start =
        match String.index_from_opt uri (query_start + 1) '#' with
        | None -> String.length uri
        | Some fragment_start -> fragment_start
      in
      let redacted = "?<redacted>" in
      let redacted_len = String.length redacted in
      let suffix_len = String.length uri - suffix_start in
      let out = Bytes.create (query_start + redacted_len + suffix_len) in
      Bytes.blit_string uri 0 out 0 query_start;
      Bytes.blit_string redacted 0 out query_start redacted_len;
      Bytes.blit_string uri suffix_start out (query_start + redacted_len)
        suffix_len;
      Bytes.unsafe_to_string out

let redact_fragment uri =
  match String.index_opt uri '#' with
  | None -> uri
  | Some fragment_start ->
      let redacted = "#<redacted>" in
      let redacted_len = String.length redacted in
      let out = Bytes.create (fragment_start + redacted_len) in
      Bytes.blit_string uri 0 out 0 fragment_start;
      Bytes.blit_string redacted 0 out fragment_start redacted_len;
      Bytes.unsafe_to_string out

let uri uri = redact_fragment (redact_query (redact_userinfo uri))
