module Json = Yojson.Safe

let usage () =
  prerr_endline "usage: compare.exe OLD_SERVER_LOAD_JSON NEW_SERVER_LOAD_JSON";
  exit 2

let assoc_find name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match assoc_find name json with Some (`String value) -> value | _ -> ""

let int_member name json =
  match assoc_find name json with
  | Some (`Int value) -> value
  | Some (`Intlit value) -> Option.value ~default:0 (int_of_string_opt value)
  | Some (`Float value) -> int_of_float value
  | _ -> 0

let number = function
  | Some (`Int value) -> Some (float value)
  | Some (`Intlit value) -> float_of_string_opt value
  | Some (`Float value) -> Some value
  | _ -> None

let nested_number names json =
  let rec loop current = function
    | [] -> number (Some current)
    | name :: rest -> (
        match assoc_find name current with
        | None -> None
        | Some next -> loop next rest)
  in
  loop json names

let key json =
  String.concat "|"
    [
      string_member "server" json;
      string_member "protocol" json;
      string_member "transport" json;
      string_member "method" json;
      string_member "path" json;
      string_member "endpoint" json;
      string_of_int (int_member "body_bytes" json);
      string_of_int (int_member "concurrency" json);
      string_of_int (int_member "http2_parallel" json);
    ]

let result_map path =
  let json = Json.from_file path in
  match assoc_find "results" json with
  | Some (`List rows) ->
      List.fold_left
        (fun acc row ->
          match string_member "status" row with
          | "pass" -> (key row, row) :: acc
          | _ -> acc)
        [] rows
  | _ -> []

let pct_delta ~old ~new_ =
  if Float.equal old 0.0 then None else Some (((new_ -. old) /. old) *. 100.0)

let direction_for_higher_better = function
  | None -> "changed"
  | Some delta when delta > 0.0 -> "improved"
  | Some delta when delta < 0.0 -> "degraded"
  | Some _ -> "same"

let direction_for_lower_better = function
  | None -> "changed"
  | Some delta when delta < 0.0 -> "improved"
  | Some delta when delta > 0.0 -> "degraded"
  | Some _ -> "same"

let json_option f = function None -> `Null | Some value -> f value

let compare_row (key, old_row) new_rows =
  match List.assoc_opt key new_rows with
  | None -> None
  | Some new_row ->
      let old_rps =
        nested_number [ "summary"; "requests_per_sec" ] old_row
      in
      let new_rps =
        nested_number [ "summary"; "requests_per_sec" ] new_row
      in
      let old_p99 = nested_number [ "latency_seconds"; "p99" ] old_row in
      let new_p99 = nested_number [ "latency_seconds"; "p99" ] new_row in
      let rps_delta =
        match (old_rps, new_rps) with
        | Some old, Some new_ -> pct_delta ~old ~new_
        | _ -> None
      in
      let p99_delta =
        match (old_p99, new_p99) with
        | Some old, Some new_ -> pct_delta ~old ~new_
        | _ -> None
      in
      Some
        (`Assoc
           [
             ("key", `String key);
             ("server", assoc_find "server" old_row |> Option.value ~default:`Null);
             ("protocol", assoc_find "protocol" old_row |> Option.value ~default:`Null);
             ("transport", assoc_find "transport" old_row |> Option.value ~default:`Null);
             ("method", assoc_find "method" old_row |> Option.value ~default:`Null);
             ("path", assoc_find "path" old_row |> Option.value ~default:`Null);
             ("endpoint", assoc_find "endpoint" old_row |> Option.value ~default:`Null);
             ("body_bytes", assoc_find "body_bytes" old_row |> Option.value ~default:`Null);
             ("concurrency", assoc_find "concurrency" old_row |> Option.value ~default:`Null);
             ("old_requests_per_sec", json_option (fun f -> `Float f) old_rps);
             ("new_requests_per_sec", json_option (fun f -> `Float f) new_rps);
             ("requests_per_sec_delta_pct", json_option (fun f -> `Float f) rps_delta);
             ( "requests_per_sec_direction",
               `String (direction_for_higher_better rps_delta) );
             ("old_p99_seconds", json_option (fun f -> `Float f) old_p99);
             ("new_p99_seconds", json_option (fun f -> `Float f) new_p99);
             ("p99_delta_pct", json_option (fun f -> `Float f) p99_delta);
             ("p99_direction", `String (direction_for_lower_better p99_delta));
           ])

let () =
  if Array.length Sys.argv <> 3 then usage ();
  let old_path = Sys.argv.(1) in
  let new_path = Sys.argv.(2) in
  let old_rows = result_map old_path in
  let new_rows = result_map new_path in
  let comparisons = List.filter_map (fun row -> compare_row row new_rows) old_rows in
  Json.to_channel stdout (`Assoc [ ("comparisons", `List comparisons) ]);
  output_char stdout '\n'
