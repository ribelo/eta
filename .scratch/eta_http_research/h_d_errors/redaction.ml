type t = { redacted_headers : string list }

let default =
  {
    redacted_headers =
      [ "authorization"; "cookie"; "set-cookie"; "x-api-key" ];
  }

let normalize name = String.lowercase_ascii (String.trim name)

let is_sensitive ?(policy = default) name =
  let normalized = normalize name in
  List.exists (String.equal normalized) policy.redacted_headers

let headers ?(policy = default) headers =
  List.map
    (fun (name, value) ->
      if is_sensitive ~policy name then (name, "<redacted>") else (name, value))
    headers

let uri uri =
  match String.index_opt uri '?' with
  | None -> uri
  | Some query_start ->
      let prefix = String.sub uri 0 query_start in
      let suffix_start =
        match String.index_from_opt uri (query_start + 1) '#' with
        | None -> String.length uri
        | Some fragment_start -> fragment_start
      in
      let suffix =
        String.sub uri suffix_start (String.length uri - suffix_start)
      in
      prefix ^ "?<redacted>" ^ suffix
