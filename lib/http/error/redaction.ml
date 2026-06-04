(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t : immutable_data = { redacted_headers : string list } [@@unboxed]

let default =
  {
    redacted_headers =
      [ "authorization"; "cookie"; "x-api-key"; "set-cookie" ];
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

let uri uri =
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
