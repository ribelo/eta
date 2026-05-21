(* probe_no_view.ml — see scratch/perf_research/journal.md for the question. *)

let int_sink = ref 0

type ('env, 'err, 'a) eff =
  | Pure : 'a -> (_, _, 'a) eff
  | Fail : 'err -> (_, 'err, _) eff
  | Bind : ('env, 'err, 'b) eff * ('b -> ('env, 'err, 'a) eff)
      -> ('env, 'err, 'a) eff
  | Catch : ('env, 'err1, 'a) eff * ('err1 -> ('env, 'err2, 'a) eff)
      -> ('env, 'err2, 'a) eff

type ('env, 'err, 'a) view =
  | V_Pure : 'a -> (_, _, 'a) view
  | V_Fail : 'err -> (_, 'err, _) view
  | V_Bind : ('env, 'err, 'b) eff * ('b -> ('env, 'err, 'a) eff)
      -> ('env, 'err, 'a) view
  | V_Catch : ('env, 'err1, 'a) eff * ('err1 -> ('env, 'err2, 'a) eff)
      -> ('env, 'err2, 'a) view

let view : type env err a. (env, err, a) eff -> (env, err, a) view = function
  | Pure v -> V_Pure v
  | Fail e -> V_Fail e
  | Bind (e, k) -> V_Bind (e, k)
  | Catch (e, h) -> V_Catch (e, h)

(* Native-exception typed-failure boundary, mirroring Typed_fail. *)
type fail_key = int
let fresh_key =
  let c = ref 0 in
  fun () -> incr c; !c
exception Raised of fail_key * Obj.t
let raise_fail k e = raise_notrace (Raised (k, Obj.repr e))

(* The recursive call into the Catch body needs a different err type
   from the outer scope. Effet handles this by giving the recursion a
   labelled `error_renderer` arg of type `'a. 'a -> string` — a
   polymorphic value. To avoid carrying it through this probe (where it
   is dead code), we instantiate the existential in the Catch arm by
   recursively calling a polymorphic-recursion-friendly version. *)

let rec interpret_with_view :
    type env err a.
    fail_key:fail_key -> sw:int -> finalizers:int ref
    -> (env, err, a) eff -> env -> a =
 fun ~fail_key ~sw ~finalizers eff env ->
  match view eff with
  | V_Pure v -> v
  | V_Fail e -> raise_fail fail_key e
  | V_Bind (e, k) ->
      let v = interpret_with_view ~fail_key ~sw ~finalizers e env in
      interpret_with_view ~fail_key ~sw ~finalizers (k v) env
  | V_Catch (e, h) ->
      let inner = fresh_key () in
      (try interpret_with_view ~fail_key:inner ~sw ~finalizers e env
       with Raised (k, payload) when k = inner ->
         let err = Obj.obj payload in
         interpret_with_view ~fail_key ~sw ~finalizers (h err) env)

let rec interpret_no_view :
    type env err a.
    fail_key:fail_key -> sw:int -> finalizers:int ref
    -> (env, err, a) eff -> env -> a =
 fun ~fail_key ~sw ~finalizers eff env ->
  match eff with
  | Pure v -> v
  | Fail e -> raise_fail fail_key e
  | Bind (e, k) ->
      let v = interpret_no_view ~fail_key ~sw ~finalizers e env in
      interpret_no_view ~fail_key ~sw ~finalizers (k v) env
  | Catch (e, h) ->
      let inner = fresh_key () in
      (try interpret_no_view ~fail_key:inner ~sw ~finalizers e env
       with Raised (k, payload) when k = inner ->
         let err = Obj.obj payload in
         interpret_no_view ~fail_key ~sw ~finalizers (h err) env)

let rec build_bind_chain n acc =
  if n = 0 then acc
  else build_bind_chain (n - 1) (Bind (acc, fun x -> Pure (x + 1)))

let rec build_fail_catch_loop n acc =
  if n = 0 then Pure acc
  else
    Catch
      ( Fail `Boom,
        fun (`Boom : [ `Boom ]) -> build_fail_catch_loop (n - 1) (acc + 1) )

(* Harness *)
type sample = { wall_ns : float; minor_words : float; major_words : float }

let sample run =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let started = Unix.gettimeofday () in
  run ();
  let ended = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  {
    wall_ns = (ended -. started) *. 1_000_000_000.;
    minor_words = after.minor_words -. before.minor_words;
    major_words = after.major_words -. before.major_words;
  }

let mean f xs =
  List.fold_left (fun acc x -> acc +. f x) 0. xs /. float_of_int (List.length xs)

let min_of f xs =
  List.fold_left (fun acc x -> Float.min acc (f x)) Float.infinity xs

let report ?(samples = 20) name f =
  let xs = List.init samples (fun _ -> sample f) in
  Printf.printf
    "%-40s wall_mean_ns=%12.0f wall_min_ns=%12.0f minor_words=%12.0f major_words=%10.0f\n%!"
    name
    (mean (fun x -> x.wall_ns) xs)
    (min_of (fun x -> x.wall_ns) xs)
    (mean (fun x -> x.minor_words) xs)
    (mean (fun x -> x.major_words) xs)

let bind_n = 100_000
let fail_n = 100_000

let run_with_view program =
  let fk = fresh_key () in
  let fz = ref 0 in
  let v = interpret_with_view ~fail_key:fk ~sw:0 ~finalizers:fz program () in
  int_sink := v

let run_no_view program =
  let fk = fresh_key () in
  let fz = ref 0 in
  let v = interpret_no_view ~fail_key:fk ~sw:0 ~finalizers:fz program () in
  int_sink := v

let () =
  Printf.printf "samples=20 bind_n=%d fail_n=%d\n%!" bind_n fail_n;
  let bind_program = build_bind_chain bind_n (Pure 0) in
  let fail_program = build_fail_catch_loop fail_n 0 in
  report "with_view.bind.100k.prebuilt" (fun () -> run_with_view bind_program);
  report "no_view.bind.100k.prebuilt" (fun () -> run_no_view bind_program);
  report "with_view.fail_catch.100k.prebuilt"
    (fun () -> run_with_view fail_program);
  report "no_view.fail_catch.100k.prebuilt"
    (fun () -> run_no_view fail_program)
