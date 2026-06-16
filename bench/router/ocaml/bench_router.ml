open Eta_router

let read_lines path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file ->
        close_in ic;
        List.rev acc
  in
  loop []

let load () =
  let routes = read_lines "../routes.txt" in
  let paths = read_lines "../paths.txt" in
  (routes, paths)

let build_router routes =
  let router = Router.create () in
  List.iter
    (fun route ->
      match Router.insert router route () with
      | Ok () -> ()
      | Error e ->
          let msg =
            match e with
            | Error.Conflict s -> "conflict: " ^ s
            | Error.Invalid_route s -> "invalid: " ^ s
          in
          failwith ("insert failed for " ^ route ^ ": " ^ msg))
    routes;
  Router.compress router;
  router

let run_lookup router paths =
  List.iter
    (fun path ->
      match Router.at router path with
      | Ok _ -> ()
      | Error _ -> failwith ("lookup failed for " ^ path))
    paths

let benchmark routes paths =
  let router = build_router routes in
  let rec loop i =
    if i = 0 then ()
    else (
      run_lookup router paths;
      loop (i - 1))
  in
  fun () -> loop 1000

let () =
  Memtrace.trace_if_requested ~context:"bench_router" ();
  let routes, paths = load () in
  let opts = Bench_lib.parse_args () in
  Bench_lib.run opts
    [
      {
        Bench_lib.name =
          Printf.sprintf "eta_router.lookup (%d routes x 1000 iters)"
            (List.length routes);
        run = benchmark routes paths;
        samples = None;
      };
    ]
