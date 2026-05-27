(* K5 — Pathological tree.

   Extremely skewed binary tree: at every level the right child is a
   tiny serial leaf, the left child recurses.  Without work-stealing
   one worker would do all the heavy work; with stealing the right
   leaves can be picked up by other workers.

   Designed to be a stress test where naive static partitioning
   (e.g., [Array.sub] + [Domain.spawn]) gets ~1× speedup, while a
   real work-stealing scheduler should approach n× on n cores. *)

let depth_default = 24
let depth_quick = 20

(* Heavy: a sin/sqrt loop that the compiler cannot fold away. *)
let heavy_work n =
  let acc = ref 0.0 in
  for i = 1 to n do
    acc := !acc +. sqrt (float_of_int i) +. sin (float_of_int i)
  done;
  !acc

let work_per_leaf_default = 1_000_000
let work_per_leaf_quick = 200_000

let rec serial_skewed depth work_per_leaf =
  if depth = 0 then heavy_work work_per_leaf
  else
    let left = serial_skewed (depth - 1) work_per_leaf in
    let right = heavy_work work_per_leaf in
    left +. right

let rec parallel_skewed depth work_per_leaf =
  if depth = 0 then heavy_work work_per_leaf
  else
    let left, right =
      Eta_par.join
        (fun () -> parallel_skewed (depth - 1) work_per_leaf)
        (fun () -> heavy_work work_per_leaf)
    in
    left +. right

let name = "pathological"
let description = "Skewed tree: every right child is a serial leaf"

(* Float checksums via printf with limited precision so serial vs parallel
   agree even with different summation order in [+. ]. *)
let fmt_checksum x = Printf.sprintf "%.0f" x

let run_serial ~quick () =
  let depth = if quick then depth_quick else depth_default in
  let w = if quick then work_per_leaf_quick else work_per_leaf_default in
  fmt_checksum (serial_skewed depth w)

let run_parallel ~quick pool =
  let depth = if quick then depth_quick else depth_default in
  let w = if quick then work_per_leaf_quick else work_per_leaf_default in
  fmt_checksum (Eta_par.Pool.run pool (fun () -> parallel_skewed depth w))
