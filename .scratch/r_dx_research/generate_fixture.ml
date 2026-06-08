let caps =
  [
    "user_query"; "user_get"; "user_run"; "user_fetch";
    "order_query"; "order_get"; "order_run"; "order_fetch";
    "cache_query"; "cache_get"; "cache_run"; "cache_fetch";
    "billing_query"; "billing_get"; "billing_run"; "billing_fetch";
    "audit_query"; "audit_get"; "audit_run"; "audit_fetch";
    "search_query"; "search_get"; "search_run"; "search_fetch";
    "notify_query"; "notify_get"; "notify_run"; "notify_fetch";
    "feature_query"; "feature_get";
  ]

let module_count = 20

let cap_index name =
  let rec loop i = function
    | [] -> invalid_arg name
    | x :: xs -> if String.equal x name then i else loop (i + 1) xs
  in
  loop 1 caps

let module_caps i =
  if i <= 10 then
    [ List.nth caps ((i - 1) * 2); List.nth caps (((i - 1) * 2) + 1) ]
  else
    [ List.nth caps (20 + (i - 11)) ]

let all_caps_until i =
  let rec loop n acc =
    if n = 0 then acc else loop (n - 1) (module_caps n @ acc)
  in
  loop i []

let mname prefix i = Printf.sprintf "%s_m%02d" prefix i
let file name = name ^ ".ml"

let write name f =
  let oc = open_out name in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> f oc)

let pp_method oc cap =
  let idx = cap_index cap in
  Printf.fprintf oc "  method %s n = n + %d\n" cap idx

let pp_service_class_method oc cap =
  Printf.fprintf oc "  method %s : int -> int\n" cap

let pp_common () =
  write "dx_common.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "class type services = object\n";
  List.iter (pp_service_class_method oc) caps;
  Printf.fprintf oc "end\n\n";
  Printf.fprintf oc "let make_services () =\n";
  Printf.fprintf oc "  object\n";
  List.iter (pp_method oc) caps;
  Printf.fprintf oc "  end\n\n";
  Printf.fprintf oc "let expected = %d\n\n" (List.length caps * (List.length caps + 1) / 2);
  Printf.fprintf oc "let run_with_env env eff =\n";
  Printf.fprintf oc "  Eio_main.run @@ fun stdenv ->\n";
  Printf.fprintf oc "  Eio.Switch.run @@ fun sw ->\n";
  Printf.fprintf oc "  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env () in\n";
  Printf.fprintf oc "  Runtime.run rt eff\n\n";
  Printf.fprintf oc "let ok = function\n";
  Printf.fprintf oc "  | Exit.Ok value -> value\n";
  Printf.fprintf oc "  | Exit.Error cause ->\n";
  Printf.fprintf oc "      failwith\n";
  Printf.fprintf oc "        (Format.asprintf \"unexpected error: %%a\"\n";
  Printf.fprintf oc "           (Cause.pp Format.pp_print_string)\n";
  Printf.fprintf oc "           cause)\n"

let pp_env_module i =
  write (file (mname "env" i)) @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  let start =
    if i = 1 then "Effect.pure 0"
    else Printf.sprintf "Env_m%02d.program ()" (i - 1)
  in
  Printf.fprintf oc "let program () =\n";
  Printf.fprintf oc "  %s\n" start;
  List.iter
    (fun cap ->
      Printf.fprintf oc
        "  |> Effect.bind (fun acc -> Effect.sync \"%s\" (fun env -> env#%s acc))\n"
        cap cap)
    (module_caps i);
  Printf.fprintf oc "\n"

let pp_env_top () =
  write "env_top.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let program () = Env_m%02d.program ()\n\n" module_count;
  Printf.fprintf oc "let run () = Dx_common.run_with_env (Dx_common.make_services ()) (program ()) |> Dx_common.ok\n"

let arg_list caps =
  caps |> List.map (fun cap -> "~" ^ cap) |> String.concat " "

let arg_forward caps =
  caps |> List.map (fun cap -> "~" ^ cap) |> String.concat " "

let pp_args_module i =
  write (file (mname "args" i)) @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  let required = all_caps_until i in
  Printf.fprintf oc "let program %s =\n" (arg_list required);
  let start =
    if i = 1 then "Effect.pure 0"
    else Printf.sprintf "Args_m%02d.program %s" (i - 1) (arg_forward (all_caps_until (i - 1)))
  in
  Printf.fprintf oc "  %s\n" start;
  List.iter
    (fun cap ->
      Printf.fprintf oc
        "  |> Effect.bind (fun acc -> Effect.sync \"%s\" (fun _ -> %s acc))\n"
        cap cap)
    (module_caps i);
  Printf.fprintf oc "\n"

let pp_args_top () =
  write "args_top.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let program %s = Args_m%02d.program %s\n\n"
    (arg_list caps) module_count (arg_forward caps);
  Printf.fprintf oc "let run () =\n";
  Printf.fprintf oc "  let services = Dx_common.make_services () in\n";
  Printf.fprintf oc "  program\n";
  List.iter
    (fun cap -> Printf.fprintf oc "    ~%s:services#%s\n" cap cap)
    caps;
  Printf.fprintf oc "  |> Dx_common.run_with_env (object end)\n";
  Printf.fprintf oc "  |> Dx_common.ok\n"

let pp_bag_module i =
  write (file (mname "bag" i)) @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let program (services : #Dx_common.services) =\n";
  let start =
    if i = 1 then "Effect.pure 0"
    else Printf.sprintf "Bag_m%02d.program services" (i - 1)
  in
  Printf.fprintf oc "  %s\n" start;
  List.iter
    (fun cap ->
      Printf.fprintf oc
        "  |> Effect.bind (fun acc -> Effect.sync \"%s\" (fun _ -> services#%s acc))\n"
        cap cap)
    (module_caps i);
  Printf.fprintf oc "\n"

let pp_bag_top () =
  write "bag_top.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let program services = Bag_m%02d.program services\n\n" module_count;
  Printf.fprintf oc "let run () = program (Dx_common.make_services ()) |> Dx_common.run_with_env (object end) |> Dx_common.ok\n"

let pp_runtime_smoke () =
  write "runtime_smoke.ml" @@ fun oc ->
  Printf.fprintf oc "let check name actual =\n";
  Printf.fprintf oc "  if actual <> Dx_common.expected then\n";
  Printf.fprintf oc "    failwith (Printf.sprintf \"%%s expected %%d got %%d\" name Dx_common.expected actual)\n\n";
  Printf.fprintf oc "let () =\n";
  Printf.fprintf oc "  check \"env-row\" (Env_top.run ());\n";
  Printf.fprintf oc "  check \"args\" (Args_top.run ());\n";
  Printf.fprintf oc "  check \"bag\" (Bag_top.run ());\n";
  Printf.fprintf oc "  Printf.printf \"r-dx smoke tests passed\\n%%!\"\n"

let pp_dune () =
  write "dune" @@ fun oc ->
  let env_modules = List.init module_count (fun i -> mname "env" (i + 1)) @ [ "env_top" ] in
  let args_modules = List.init module_count (fun i -> mname "args" (i + 1)) @ [ "args_top" ] in
  let bag_modules = List.init module_count (fun i -> mname "bag" (i + 1)) @ [ "bag_top" ] in
  let pp_modules mods = List.iter (fun m -> Printf.fprintf oc "  %s\n" m) mods in
  Printf.fprintf oc "(library\n (name r_dx_common)\n (wrapped false)\n (libraries effet eio_main)\n (modules dx_common))\n\n";
  Printf.fprintf oc "(library\n (name r_dx_env_row)\n (wrapped false)\n (libraries effet r_dx_common)\n (modules\n";
  pp_modules env_modules;
  Printf.fprintf oc " ))\n\n";
  Printf.fprintf oc "(library\n (name r_dx_args)\n (wrapped false)\n (libraries effet r_dx_common)\n (modules\n";
  pp_modules args_modules;
  Printf.fprintf oc " ))\n\n";
  Printf.fprintf oc "(library\n (name r_dx_bag)\n (wrapped false)\n (libraries effet r_dx_common)\n (modules\n";
  pp_modules bag_modules;
  Printf.fprintf oc " ))\n\n";
  Printf.fprintf oc "(executable\n (name runtime_smoke)\n (libraries r_dx_common r_dx_env_row r_dx_args r_dx_bag)\n (modules runtime_smoke))\n"

let pp_negatives () =
  write "neg_env_missing_cap.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let env =\n  object\n";
  List.iter
    (fun cap -> if not (String.equal cap "billing_fetch") then pp_method oc cap)
    caps;
  Printf.fprintf oc "  end\n\n";
  Printf.fprintf oc "let _ : (int, string Cause.t) result = Dx_common.run_with_env env (Env_top.program ())\n";
  write "neg_args_missing_cap.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let services = Dx_common.make_services ()\n\n";
  Printf.fprintf oc "let _ : (<  >, string, int) Effect.t =\n";
  Printf.fprintf oc "  Args_top.program\n";
  List.iter
    (fun cap ->
      if not (String.equal cap "billing_fetch") then
        Printf.fprintf oc "    ~%s:services#%s\n" cap cap)
    caps;
  write "neg_bag_shape_refactor.ml" @@ fun oc ->
  Printf.fprintf oc "let services =\n  object\n";
  List.iter
    (fun cap ->
      if String.equal cap "billing_fetch" then
        Printf.fprintf oc "  method %s s = String.length s\n" cap
      else pp_method oc cap)
    caps;
  Printf.fprintf oc "  end\n\n";
  Printf.fprintf oc "let _ = Bag_top.program services\n";
  write "neg_env_collision.ml" @@ fun oc ->
  Printf.fprintf oc "open Effet\n\n";
  Printf.fprintf oc "let a = Effect.sync \"query-int\" (fun env -> env#query 1)\n";
  Printf.fprintf oc "let b = Effect.sync \"query-string\" (fun env -> env#query \"x\")\n";
  Printf.fprintf oc "let c = Effect.sync \"get-int\" (fun env -> env#get 1)\n";
  Printf.fprintf oc "let d = Effect.sync \"get-string\" (fun env -> env#get \"x\")\n";
  Printf.fprintf oc "let _bad =\n";
  Printf.fprintf oc "  a |> Effect.bind (fun _ -> b)\n";
  Printf.fprintf oc "    |> Effect.bind (fun _ -> c)\n";
  Printf.fprintf oc "    |> Effect.bind (fun _ -> d)\n"

let pp_measure () =
  write "measure.sh" @@ fun oc ->
  Printf.fprintf oc "#!/usr/bin/env bash\n";
  Printf.fprintf oc "set -euo pipefail\n";
  Printf.fprintf oc "cd \"$(dirname \"$0\")/../..\"\n";
  Printf.fprintf oc "mkdir -p scratch/r_dx_research/results\n";
  Printf.fprintf oc "measure() { out=\"$1\"; cmd=\"$2\"; start=$(date +%%s%%3N); bash -c \"$cmd\"; end=$(date +%%s%%3N); printf 'elapsed_ms=%%s\\n' \"$((end - start))\" > \"$out\"; }\n";
  Printf.fprintf oc "rm -rf _build/default/scratch/r_dx_research\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/build_clean_all.txt 'dune build scratch/r_dx_research'\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/build_incremental_noop.txt 'dune build scratch/r_dx_research'\n";
  Printf.fprintf oc "rm -rf _build/default/scratch/r_dx_research/.r_dx_env_row.objs\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/build_clean_env_row.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_env_row.objs/byte/env_top.cmi'\n";
  Printf.fprintf oc "rm -rf _build/default/scratch/r_dx_research/.r_dx_args.objs\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/build_clean_args.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_args.objs/byte/args_top.cmi'\n";
  Printf.fprintf oc "rm -rf _build/default/scratch/r_dx_research/.r_dx_bag.objs\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/build_clean_bag.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_bag.objs/byte/bag_top.cmi'\n";
  Printf.fprintf oc "touch scratch/r_dx_research/env_m10.ml\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/rebuild_env_touch.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_env_row.objs/byte/env_top.cmi'\n";
  Printf.fprintf oc "touch scratch/r_dx_research/args_m10.ml\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/rebuild_args_touch.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_args.objs/byte/args_top.cmi'\n";
  Printf.fprintf oc "touch scratch/r_dx_research/bag_m10.ml\n";
  Printf.fprintf oc "measure scratch/r_dx_research/results/rebuild_bag_touch.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_bag.objs/byte/bag_top.cmi'\n";
  Printf.fprintf oc "ocamlc -i -I _build/default/packages/effet/.effet.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_common.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_env_row.objs/byte scratch/r_dx_research/env_top.ml > scratch/r_dx_research/results/env_top.i 2>&1 || true\n";
  Printf.fprintf oc "ocamlc -i -I _build/default/packages/effet/.effet.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_common.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_args.objs/byte scratch/r_dx_research/args_top.ml > scratch/r_dx_research/results/args_top.i 2>&1 || true\n";
  Printf.fprintf oc "ocamlc -i -I _build/default/packages/effet/.effet.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_common.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_bag.objs/byte scratch/r_dx_research/bag_top.ml > scratch/r_dx_research/results/bag_top.i 2>&1 || true\n"

let () =
  Sys.chdir (Filename.dirname Sys.argv.(0));
  pp_dune ();
  pp_common ();
  for i = 1 to module_count do
    pp_env_module i;
    pp_args_module i;
    pp_bag_module i
  done;
  pp_env_top ();
  pp_args_top ();
  pp_bag_top ();
  pp_runtime_smoke ();
  pp_negatives ();
  pp_measure ()
