type measurement = {
  name : string;
  metric : string;
  mean : float;
  unit_ : string;
}

let usage () =
  prerr_endline
    "usage: dune exec bench/compare.exe -- [<left.json> <right.json>]";
  exit 2

let default_results_dir = "bench/results"

let latest_two_results () =
  let files =
    Sys.readdir default_results_dir |> Array.to_list
    |> List.filter (fun file -> Filename.check_suffix file ".json")
    |> List.sort String.compare
    |> List.map (Filename.concat default_results_dir)
  in
  match List.rev files with
  | right :: left :: _ -> (left, right)
  | _ ->
      prerr_endline
        ("bench/compare: need at least two .json files in " ^ default_results_dir);
      usage ()

let load path =
  let json = Yojson.Safe.from_file path in
  let open Yojson.Safe.Util in
  json |> member "benchmarks" |> to_list
  |> List.map (fun item ->
         {
           name = item |> member "name" |> to_string;
           metric = item |> member "metric" |> to_string;
           mean = item |> member "mean" |> to_float;
           unit_ = item |> member "unit" |> to_string;
         })

let key m = m.name ^ "|" ^ m.metric

let table xs =
  let tbl = Hashtbl.create (List.length xs) in
  List.iter (fun m -> Hashtbl.replace tbl (key m) m) xs;
  tbl

let compare left right =
      let left_tbl = table (load left) in
      let right_values = load right in
      Printf.printf "left:  %s\nright: %s\n\n" left right;
      Printf.printf "%-54s %-14s %14s %14s %12s\n" "benchmark" "metric" "left" "right" "delta%";
      List.iter
        (fun r ->
          match Hashtbl.find_opt left_tbl (key r) with
          | None -> ()
          | Some l ->
              let delta =
                if l.mean = 0. then 0. else ((r.mean -. l.mean) /. l.mean) *. 100.
              in
              Printf.printf "%-54s %-14s %14.2f %14.2f %11.2f%% %s\n"
                r.name r.metric l.mean r.mean delta r.unit_)
        right_values

let () =
  match Array.to_list Sys.argv with
  | [ _ ] ->
      let left, right = latest_two_results () in
      compare left right
  | [ _; left; right ] -> compare left right
  | _ -> usage ()
