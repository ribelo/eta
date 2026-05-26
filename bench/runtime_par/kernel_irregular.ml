(* K6 — Irregular par_reduce.

   par_reduce over a range, each iteration has a cost that varies with
   the index in a way the scheduler cannot predict.  Static
   partitioning gives uneven load; heartbeat-driven promotion should
   balance.

   Cost profile: a sin-modulated busy loop, so adjacent indices have
   similar cost (cache-friendly per worker chunk) but the cost of
   different chunks differs by ~10x.

   Note: we use [par_reduce] with sum so the parallel version has no
   shared mutable state.  An earlier draft used [par_for] with an
   atomic counter, which gave the parallel version contention
   overhead the serial baseline did not pay — that was not an
   apples-to-apples comparison. *)

let n_default = 20_000
let n_quick = 5_000

let cost_of_index i =
  (* In the range ~50..~5050 *)
  50 + int_of_float ((sin (float_of_int i *. 0.001) +. 1.0) *. 2500.0)

(* Heavy work: integer mixing.  Returns the final accumulator. *)
let busy n =
  let mutable acc = 0 in
  for j = 1 to n do
    acc <- acc + j * j
  done;
  acc

let serial_run n =
  let acc = ref 0 in
  for i = 0 to n - 1 do
    acc := !acc + busy (cost_of_index i)
  done;
  !acc

let parallel_run n =
  (* Build an index array and reduce.  combine = (+) so the order of
     reduction does not affect the result; identity 0 is the left
     identity for [+]. *)
  let idx = Array.init n Fun.id in
  Par.par_reduce idx
    ~init:0
    ~map:(fun i -> busy (cost_of_index i))
    ~combine:( + )

let name = "irregular"
let description = "par_reduce with index-dependent cost (sin-modulated busy loop)"

let run_serial ~quick () =
  let n = if quick then n_quick else n_default in
  string_of_int (serial_run n)

let run_parallel ~quick pool =
  let n = if quick then n_quick else n_default in
  let r = Par.Pool.run pool (fun () -> parallel_run n) in
  string_of_int r
