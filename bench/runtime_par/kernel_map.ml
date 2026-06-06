(* K3 — Parallel map over a large array.

   Regular per-element work, no inter-task communication.  This is the
   easiest case for a work-stealing scheduler: deque ops are cold, most
   tasks run on their owner.  Per-element work is calibrated so the
   serial baseline takes hundreds of milliseconds — much smaller and
   the scheduling overhead would dominate. *)

let n_default = 4_000_000
let n_quick = 1_000_000

(* Per-element work: 32 rounds of a mixing function.  Heavy enough that
   the indirect call to [f] in [par_map] is amortised. *)
let work x =
  let y = ref x in
  for _ = 1 to 32 do
    y := ((!y * 2654435761) lxor (!y lsr 13)) land 0x3FFFFFFF
  done;
  !y

let make_input n = Array.init n Fun.id

let checksum arr =
  let n = Array.length arr in
  Printf.sprintf "%d:%d:%d" n arr.(0) arr.(n - 1)

let name = "par_map"
let description = "par_map over a 4M-element int array, 32 rounds of mixing per element"

let run_serial ~quick () =
  let n = if quick then n_quick else n_default in
  let input = make_input n in
  let output = Array.map work input in
  checksum output

let run_parallel ~quick pool =
  let n = if quick then n_quick else n_default in
  let input = make_input n in
  let output = Eta.Par.Pool.run pool (fun () -> Eta.Par.par_map input work) in
  checksum output
