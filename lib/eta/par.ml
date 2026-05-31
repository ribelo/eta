(* Eta.Par — public facade for the parallel runtime. *)

module Pool = Par_runtime.Pool

let run = Par_runtime.run
let join = Par_runtime.join
let join3 = Par_runtime.join3

let par_for = Par_array.par_for
let par_iter = Par_array.par_iter
let par_iteri = Par_array.par_iteri
let par_map = Par_array.par_map
let par_mapi = Par_array.par_mapi
let par_reduce = Par_array.par_reduce
let par_sort = Par_array.par_sort

module Iter = Par_iter
