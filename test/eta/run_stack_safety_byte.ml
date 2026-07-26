(* DX-E35 bytecode stack-safety gate. eta.cma is a shipped artifact, so the
   measured 1M contract is pinned in bytecode as well as native and
   js_of_ocaml. Mirrors the native Alcotest cases in
   test_eta_effect_core.ml; see .scratch/research/dx/e35/report.md for the
   full guarantee statement and its configuration boundaries. *)

open Eta

let depth = 1_000_000

let fail message =
  prerr_endline ("stack-safety byte gate failed: " ^ message);
  exit 1

let pp_cause =
  Cause.pp (fun fmt (_ : string) -> Format.pp_print_string fmt "<err>")

let check_dynamic_bind rt =
  let rec next remaining value =
    if remaining = 0 then Effect.pure value
    else
      Effect.bind
        (fun value -> next (remaining - 1) (value + 1))
        (Effect.pure value)
  in
  match Runtime.run rt (next depth 0) with
  | Exit.Ok value when value = depth -> ()
  | Exit.Ok value ->
      fail (Printf.sprintf "dynamic_bind: expected %d, got %d" depth value)
  | Exit.Error cause -> fail (Format.asprintf "dynamic_bind: %a" pp_cause cause)

let check_static_map rt =
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Effect.map (fun value -> value + 1) acc)
  in
  match Runtime.run rt (build depth (Effect.pure 0)) with
  | Exit.Ok value when value = depth -> ()
  | Exit.Ok value ->
      fail (Printf.sprintf "static_map: expected %d, got %d" depth value)
  | Exit.Error cause -> fail (Format.asprintf "static_map: %a" pp_cause cause)

let check_concat rt =
  let executed = ref 0 in
  let rec build remaining acc =
    if remaining = 0 then acc
    else
      build (remaining - 1)
        (Effect.sync (fun () -> incr executed) :: acc)
  in
  match Runtime.run rt (Effect.concat (build depth [])) with
  | Exit.Ok () when !executed = depth -> ()
  | Exit.Ok () ->
      fail
        (Printf.sprintf "concat: expected %d executions, got %d" depth
           !executed)
  | Exit.Error cause -> fail (Format.asprintf "concat: %a" pp_cause cause)

let check_bind_error rt =
  let handled = ref 0 in
  let recover (_ : string) =
    incr handled;
    Effect.fail "boom"
  in
  let rec build remaining acc =
    if remaining = 0 then acc
    else build (remaining - 1) (Effect.bind_error recover acc)
  in
  match Runtime.run rt (build depth (Effect.fail "boom")) with
  | Exit.Error (Cause.Fail "boom") when !handled = depth -> ()
  | Exit.Error (Cause.Fail "boom") ->
      fail
        (Printf.sprintf "bind_error: expected %d recovery runs, got %d" depth
           !handled)
  | Exit.Error cause -> fail (Format.asprintf "bind_error: %a" pp_cause cause)
  | Exit.Ok _ -> fail "bind_error: recovery chain lost the typed failure"

let check_cause_tree name combine =
  let cause = ref (Cause.fail 0) in
  for value = 1 to depth do
    cause := combine [ !cause; Cause.fail value ]
  done;
  let rec check_leaf index = function
    | [] ->
        if index <> depth + 1 then
          fail
            (Printf.sprintf "%s: expected %d leaves, got %d" name (depth + 1)
               index)
    | leaf :: rest ->
        if leaf <> index then
          fail
            (Printf.sprintf "%s: leaf at index %d: expected %d, got %d" name
               index index leaf);
        check_leaf (index + 1) rest
  in
  check_leaf 0 (Cause.failures !cause)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  check_dynamic_bind rt;
  check_static_map rt;
  check_concat rt;
  check_bind_error rt;
  check_cause_tree "sequential" Cause.sequential;
  check_cause_tree "concurrent" Cause.concurrent;
  Printf.printf "stack-safety byte gate ok (%d steps per case)\n" depth
