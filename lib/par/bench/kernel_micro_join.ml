(* K8 — Micro joins.

   Tons of tiny joins on near-trivial work.  This is a stress test for
   scheduler overhead per [join]: per-task work is small enough that
   spawn / steal / finish costs dominate.

   It is *not* a workload anyone would write deliberately — it is the
   worst case the scheduler may face when an algorithm decomposes too
   far.  A well-tuned scheduler should still match (not catastrophically
   underperform) the serial version. *)

let depth_default = 16
let depth_quick = 14

(* Tiny work per leaf — a few hundred cycles. *)
let leaf_work x =
  let mutable y = x in
  for _ = 1 to 4 do
    y <- ((y * 2654435761) lxor (y lsr 13)) land 0x3FFFFFFF
  done;
  y

let rec serial_tree depth seed =
  if depth = 0 then leaf_work seed
  else
    serial_tree (depth - 1) (seed * 3 + 1)
    + serial_tree (depth - 1) (seed * 3 + 2)

let rec parallel_tree depth seed =
  if depth = 0 then leaf_work seed
  else
    let a, b =
      Eta.Par.join
        (fun () -> parallel_tree (depth - 1) (seed * 3 + 1))
        (fun () -> parallel_tree (depth - 1) (seed * 3 + 2))
    in
    a + b

let name = "micro_join"
let description = "Many shallow joins on tiny per-leaf work — scheduler overhead probe"

let run_serial ~quick () =
  let d = if quick then depth_quick else depth_default in
  string_of_int (serial_tree d 1)

let run_parallel ~quick pool =
  let d = if quick then depth_quick else depth_default in
  string_of_int (Eta.Par.Pool.run pool (fun () -> parallel_tree d 1))
