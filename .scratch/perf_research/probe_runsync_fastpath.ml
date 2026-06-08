(* probe_runsync_fastpath.ml
 *
 * Question: how much of the per-call cost of `Runtime.run rt (Effect.pure 0)`
 * is the `Eio.Switch.run` + tracer-context + finalizers-ref + try/with +
 * Exit.Ok wrapper? Effect-v4 fast-paths runSync(succeed) to a single
 * property check, ~3.9 ns/call. Effet currently costs ~2.86 µs/call.
 *
 * Method: use the public Effet API for the baseline (Runtime.run with
 * Eio.Switch.run, etc.), and a "fast-path-aware" wrapper that, when the
 * AST head is Pure/Fail, returns immediately without entering Switch.run.
 *
 * The probe deliberately reuses the same `Runtime.t` across iterations
 * to mirror the apples_to_apples row "effet.pure.reused_rt".
 *)

open Effet
module EP = Effect.Private

let int_sink = ref 0

(* run_fast: top-level fast-path for Pure/Fail. Anything else falls
   through to the canonical Runtime.run. *)
let run_fast rt eff =
  match EP.view eff with
  | EP.Pure v -> Exit.Ok v
  | _ -> Runtime.run rt eff

(* run_fast_no_view: same idea but matches on the t directly via the same
   mechanism Effet's internal interpret would use. We can't see the
   private constructors from outside the package, so we emulate the
   "no-view" headline by using EP.view exactly once and then dispatching
   to Runtime.run for the non-fast cases. The realistic implementation
   would live inside Runtime.run and would not pay even one view alloc
   for the fast path. We approximate that by avoiding the *full* run
   path for Pure. *)

type sample = { wall_ns : float; minor_words : float }
let sample run =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let started = Unix.gettimeofday () in
  run ();
  let ended = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  { wall_ns = (ended -. started) *. 1_000_000_000.;
    minor_words = after.minor_words -. before.minor_words }

let mean f xs =
  List.fold_left (fun acc x -> acc +. f x) 0. xs /. float_of_int (List.length xs)

let min_of f xs = List.fold_left (fun a x -> Float.min a (f x)) Float.infinity xs

(* Per-call timing is at the timer floor, so each "run" loops 100k
   times and the per-call value is the wall divided by the loop count.
   This is the same trick we already use for the TS reference. *)
let pure_eff = Effect.pure 0
let loops = 100_000

let run_loop_baseline rt =
  for _ = 1 to loops do
    match Runtime.run rt pure_eff with
    | Exit.Ok v -> int_sink := v
    | _ -> failwith "unreachable"
  done

let run_loop_fast rt =
  for _ = 1 to loops do
    match run_fast rt pure_eff with
    | Exit.Ok v -> int_sink := v
    | _ -> failwith "unreachable"
  done

let report ?(samples = 10) name f =
  let xs = List.init samples (fun _ -> sample f) in
  let wall_mean = mean (fun x -> x.wall_ns) xs in
  let wall_min = min_of (fun x -> x.wall_ns) xs in
  let words = mean (fun x -> x.minor_words) xs in
  Printf.printf
    "%-40s wall_mean_ns=%12.0f (%6.1f ns/call)  wall_min_ns=%12.0f (%6.1f ns/call)  minor_words/call=%6.2f\n%!"
    name
    wall_mean
    (wall_mean /. float_of_int loops)
    wall_min
    (wall_min /. float_of_int loops)
    (words /. float_of_int loops)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  Printf.printf "samples=10 loops/sample=%d effect=Effect.pure 0\n%!" loops;
  report "runSync.baseline.Switch_run" (fun () -> run_loop_baseline rt);
  report "runSync.fast_path.Pure" (fun () -> run_loop_fast rt)
