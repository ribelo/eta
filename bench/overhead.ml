type measurement = {
  name : string;
  metric : string;
  mean : float;
  unit_ : string;
}

let default_results_dir = "bench/results"

let usage () =
  prerr_endline "usage: dune exec bench/overhead.exe -- [result.json]";
  exit 2

let latest_result () =
  let files =
    Sys.readdir default_results_dir |> Array.to_list
    |> List.filter (fun file -> Filename.check_suffix file ".json")
    |> List.sort String.compare
    |> List.map (Filename.concat default_results_dir)
  in
  match List.rev files with
  | path :: _ -> path
  | [] ->
      prerr_endline
        ("bench/overhead: need at least one .json file in " ^ default_results_dir);
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

let table xs =
  let tbl = Hashtbl.create (List.length xs) in
  List.iter (fun m -> Hashtbl.replace tbl (m.name ^ "|" ^ m.metric) m) xs;
  tbl

let get tbl name metric = Hashtbl.find_opt tbl (name ^ "|" ^ metric)

let ratio tbl ~name ~left ~right ~metric =
  match (get tbl left metric, get tbl right metric) with
  | Some l, Some r when r.mean <> 0. ->
      Some (name, l.mean, r.mean, l.mean /. r.mean, l.unit_)
  | _ -> None

let print_ratio (name, left, right, ratio, unit_) =
  Printf.printf "%-44s %14.2f %14.2f %10.2fx %s\n" name left right ratio unit_

let () =
  let path =
    match Array.to_list Sys.argv with
    | [ _ ] -> latest_result ()
    | [ _; path ] -> path
    | _ -> usage ()
  in
  let tbl = table (load path) in
  Printf.printf "result: %s\n\n" path;
  Printf.printf "%-44s %14s %14s %10s %s\n" "ratio" "eta" "baseline" "ratio" "unit";
  [
    ratio tbl ~metric:"wall_ns" ~name:"bind.prebuilt.time"
      ~left:"overhead.eta.bind.100k.prebuilt"
      ~right:"overhead.mini.bind.100k.prebuilt";
    ratio tbl ~metric:"minor_words" ~name:"bind.prebuilt.minor_words"
      ~left:"overhead.eta.bind.100k.prebuilt"
      ~right:"overhead.mini.bind.100k.prebuilt";
    ratio tbl ~metric:"major_words" ~name:"bind.prebuilt.major_words"
      ~left:"overhead.eta.bind.100k.prebuilt"
      ~right:"overhead.mini.bind.100k.prebuilt";
    ratio tbl ~metric:"wall_ns" ~name:"bind.build_run.time"
      ~left:"overhead.eta.bind.100k.build_run"
      ~right:"overhead.mini.bind.100k.build_run";
    ratio tbl ~metric:"minor_words" ~name:"bind.build_run.minor_words"
      ~left:"overhead.eta.bind.100k.build_run"
      ~right:"overhead.mini.bind.100k.build_run";
    ratio tbl ~metric:"major_words" ~name:"bind.build_run.major_words"
      ~left:"overhead.eta.bind.100k.build_run"
      ~right:"overhead.mini.bind.100k.build_run";
    ratio tbl ~metric:"wall_ns" ~name:"fail_catch.prebuilt.time"
      ~left:"overhead.eta.fail_catch.100k.prebuilt"
      ~right:"overhead.mini.fail_catch.100k.prebuilt";
    ratio tbl ~metric:"minor_words" ~name:"fail_catch.prebuilt.minor_words"
      ~left:"overhead.eta.fail_catch.100k.prebuilt"
      ~right:"overhead.mini.fail_catch.100k.prebuilt";
    ratio tbl ~metric:"major_words" ~name:"fail_catch.prebuilt.major_words"
      ~left:"overhead.eta.fail_catch.100k.prebuilt"
      ~right:"overhead.mini.fail_catch.100k.prebuilt";
    ratio tbl ~metric:"wall_ns" ~name:"fail_catch.build_run.time"
      ~left:"overhead.eta.fail_catch.100k.build_run"
      ~right:"overhead.mini.fail_catch.100k.build_run";
    ratio tbl ~metric:"minor_words" ~name:"fail_catch.build_run.minor_words"
      ~left:"overhead.eta.fail_catch.100k.build_run"
      ~right:"overhead.mini.fail_catch.100k.build_run";
    ratio tbl ~metric:"major_words" ~name:"fail_catch.build_run.major_words"
      ~left:"overhead.eta.fail_catch.100k.build_run"
      ~right:"overhead.mini.fail_catch.100k.build_run";
    ratio tbl ~metric:"wall_ns" ~name:"setup.time"
      ~left:"overhead.eta.setup_pure"
      ~right:"overhead.eio.setup";
  ]
  |> List.iter (function
       | Some item -> print_ratio item
       | None -> ());
  ignore tbl

