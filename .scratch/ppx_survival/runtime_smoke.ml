let run_ok rt eff =
  match Effet.Runtime.run rt eff with
  | Effet.Exit.Ok value -> value
  | Effet.Exit.Error _ -> failwith "expected Ok"

let span_names tracer =
  List.map (fun span -> span.Effet.Tracer.name) (Effet.Tracer.dump tracer)

let check_suffix label suffix names =
  if not (List.exists (fun name -> String.ends_with ~suffix name) names) then
    failwith
      (Printf.sprintf "%s: expected suffix %S in [%s]" label suffix
         (String.concat "; " names))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let env = object end in
  let tracer = Effet.Tracer.in_memory () in
  let rt =
    Effet.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Effet.Tracer.as_capability tracer) ~env ()
  in
  ignore (run_ok rt (Ppx_survival.Golden_cases.top_level ()) : int);
  ignore (run_ok rt (Ppx_survival.Golden_cases.nested_function ()) : int);
  ignore
    (List.map (run_ok rt) (Ppx_survival.Golden_cases.anonymous_lambda ())
      : int list);
  ignore (run_ok rt (Ppx_survival.Golden_cases.partial_application "p") : string);
  ignore (run_ok rt (Ppx_survival.Golden_cases.local_module ()) : int);
  let names = span_names tracer in
  check_suffix "top_level" ".top_level" names;
  check_suffix "nested inner" ".inner" names;
  check_suffix "anonymous lambda" ".anonymous_lambda.(fun)" names;
  check_suffix "partial application" ".partial_application" names;
  check_suffix "local module" ".local_module" names;
  let auth = { Ppx_survival.Golden_cases.Auth.user = "alice" } in
  let env = Ppx_survival.Golden_cases.env_builder auth in
  let tracer = Effet.Tracer.in_memory () in
  let rt =
    Effet.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Effet.Tracer.as_capability tracer) ~env ()
  in
  ignore (run_ok rt (Ppx_survival.Golden_cases.thunk_leaf ()) : string);
  check_suffix "thunk leaf" ".thunk_leaf" (span_names tracer);
  print_endline "ppx_survival runtime smoke passed"
