(* K4 — Tree reduction.

   par_reduce builds a balanced binary reduction tree.  This kernel uses
   a non-trivial [combine] (so we exercise something other than integer
   addition) and a [map] step that does meaningful per-element work. *)

let n_default = 8_000_000
let n_quick = 2_000_000

(* map: hash-mix the input.  combine: max.  Identity for max is min_int.
   24 rounds gives substantial per-element work so par_reduce's
   indirect calls don't dominate. *)
let map_fn x =
  let y = ref x in
  for _ = 1 to 24 do
    y := ((!y * 2654435761) lxor (!y lsr 13)) land 0x3FFFFFFF
  done;
  !y

let make_input n = Array.init n (fun i -> i + 1)

let name = "par_reduce"
let description = "par_reduce: max of mixed values over an 8M-element int array"

let run_serial ~quick () =
  let n = if quick then n_quick else n_default in
  let input = make_input n in
  let acc = ref min_int in
  for i = 0 to n - 1 do
    acc := max !acc (map_fn input.(i))
  done;
  string_of_int !acc

let run_parallel ~quick pool =
  let n = if quick then n_quick else n_default in
  let input = make_input n in
  let r =
    Eta_par.Pool.run pool (fun () ->
      Eta_par.par_reduce input ~init:min_int ~map:map_fn ~combine:max)
  in
  string_of_int r
