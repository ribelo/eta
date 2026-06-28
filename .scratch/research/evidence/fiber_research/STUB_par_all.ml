(* Implementation stub for V-F1 (F-A: collection combinators).

   This file is a SKETCH, not a working module. It documents the
   exact additions to lib/effect.{ml,mli} and lib/runtime.ml that
   the journal entry V-F1..V-F4 commits to. Drop into the real
   library files at implementation time.

   Total estimated size: ~110 LOC (public) + ~30 LOC (internal helper)
   + ~80 LOC (tests).
*)

(* ============================================================
   lib/effect.mli additions
   ============================================================ *)

(*
type ('env, 'err, 'a) t =
  | ...                      (* existing constructors *)
  | Par : ('env, 'err, 'a) t * ('env, 'err, 'b) t
        -> ('env, 'err, 'a * 'b) t
  | All : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
  | For_each_par :
      'x list * ('x -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a list) t

val par :
  ('env, 'err, 'a) t -> ('env, 'err, 'b) t -> ('env, 'err, 'a * 'b) t
(** Run two effects concurrently. Fail-fast: the first child failure
    cancels the sibling and the cause propagates upward. *)

val all : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
(** Run effects concurrently, collecting results in input order.
    Fail-fast: the first child failure cancels the others; the cause
    of the first observed failure propagates. *)

val for_each_par :
  'x list -> ('x -> ('env, 'err, 'a) t) -> ('env, 'err, 'a list) t
(** Map over [xs] concurrently with [f], collecting results in input
    order. Fail-fast like [all]. *)
*)

(* ============================================================
   lib/effect.ml additions
   ============================================================ *)

(*
let par a b = Par (a, b)
let all xs = All xs
let for_each_par xs f = For_each_par (xs, f)

(* Add to collect_names walk: *)
| Par (a, b) -> walk (walk acc a) b
| All xs -> List.fold_left walk acc xs
| For_each_par _ -> acc  (* leaves are inside continuations *)
*)

(* ============================================================
   lib/runtime.ml additions
   ============================================================ *)

(*
(* Add to interpret: *)
| E.Par (a, b) ->
    par_collect ~runtime ~fail_key ~finalizers env [
      (fun () -> Obj.repr (interpret ~runtime ~fail_key ~sw ~finalizers a env));
      (fun () -> Obj.repr (interpret ~runtime ~fail_key ~sw ~finalizers b env));
    ]
    |> (function
         | [ va; vb ] -> (Obj.obj va, Obj.obj vb)
         | _ -> assert false)

| E.All xs ->
    par_collect_list ~runtime ~fail_key ~finalizers env
      (List.map
         (fun child () ->
            interpret ~runtime ~fail_key ~sw ~finalizers child env)
         xs)

| E.For_each_par (xs, f) ->
    par_collect_list ~runtime ~fail_key ~finalizers env
      (List.map
         (fun x () ->
            interpret ~runtime ~fail_key ~sw ~finalizers (f x) env)
         xs)

(* Helper: fail-fast concurrent collection through a per-call switch. *)
and par_collect_list :
    type re env err a.
    runtime:(re, _) t ->
    fail_key:Typed_fail.key ->
    finalizers:(unit -> unit) list ref ->
    env -> (unit -> a) list -> a list =
 fun ~runtime ~fail_key ~finalizers _env children ->
  let n = List.length children in
  let results = Array.make n None in
  let first_cause = ref None in
  let exception Stop in
  (try
     Eio.Switch.run @@ fun par_sw ->
     List.iteri
       (fun i task ->
         Eio.Fiber.fork ~sw:par_sw (fun () ->
             try
               results.(i) <- Some (task ())
             with exn ->
               if !first_cause = None then
                 first_cause := Some (cause_of_exn fail_key exn);
               Eio.Switch.fail par_sw Stop))
       children
   with Stop -> ());
  match !first_cause with
  | Some c -> raise_cause fail_key c
  | None ->
      Array.to_list results
      |> List.map (fun o -> Option.get o)

(* Note: ignore unused [finalizers] / [_env] above; the real helper
   takes them for symmetry with other interpreter helpers. *)
*)

(* ============================================================
   test/test_effet.ml additions (sketch)
   ============================================================ *)

(*
let test_par_returns_both_successes () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt (Effect.par (Effect.pure 1) (Effect.pure 2))
  in
  Alcotest.(check (pair int int)) "par returns pair" (1, 2) result

let test_par_fail_fast_cancels_sibling () = ...

let test_all_collects_in_input_order () =
  with_runtime @@ fun rt ->
  let result =
    run_ok rt
      (Effect.all
         [ Effect.pure 1; Effect.pure 2; Effect.pure 3 ])
  in
  Alcotest.(check (list int)) "all order" [ 1; 2; 3 ] result

let test_all_fail_fast_returns_first_cause () = ...
let test_for_each_par_success () = ...
let test_for_each_par_one_fails () = ...
*)

(* ============================================================
   Internal-only fork helper (NOT in mli)
   ============================================================ *)

(*
(* runtime.ml: visible only inside the library. *)

val fork_internal :
  runtime:('env, 'err) t ->
  sw:Eio.Switch.t ->
  ('env, 'err, 'a) Effect.t ->
  'env ->
  ('a, 'err Cause.t) result Eio.Promise.t

(* Used by Resource.auto (deferred) and the par/all/for_each_par
   implementations. NOT exposed in any .mli of a public module. *)
*)
