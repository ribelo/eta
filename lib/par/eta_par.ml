(* Eta_par — native heartbeat-backed parallel runtime. *)

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

module Island = struct
  type worker_die = Island_runtime.worker_die = {
    kind : string;
    message : string;
    backtrace : string option;
  }

  type ('a, 'e) settled =
    ('a, 'e) Island_runtime.settled =
    | Ok of 'a
    | Error of 'e
    | Worker_died of worker_die

  type pool = Island_runtime.pool
  module Pool = Island_runtime.Pool

  let submit_wait ?(name = "island") ~pool f =
    Eta_blocking.run ~pool:(Island_runtime.wait_pool pool)
      ~name:("island.wait." ^ name) f

  let run ?name ~pool f input =
    let name = Option.value name ~default:"island" in
    submit_wait ~name ~pool (fun () -> Island_runtime.submit name pool f input)

  let map ?name ~pool ~f inputs =
    let name = Option.value name ~default:"island.map" in
    submit_wait ~name ~pool (fun () ->
        Island_runtime.submit_map name pool f inputs)

  let map_result ?name ~pool ~f inputs =
    let name = Option.value name ~default:"island.map_result" in
    submit_wait ~name ~pool (fun () ->
        Island_runtime.submit_map_result name pool f inputs)

  let all_settled ?name ~pool ~f inputs =
    let name = Option.value name ~default:"island.all_settled" in
    submit_wait ~name ~pool (fun () ->
        Island_runtime.submit_all_settled pool f inputs)

  module type POOL = sig
    val pool : pool
  end

  module Make (P : POOL) = struct
    let run ?name f input = run ?name ~pool:P.pool f input
    let map ?name ~f inputs = map ?name ~pool:P.pool ~f inputs
    let map_result ?name ~f inputs = map_result ?name ~pool:P.pool ~f inputs
    let all_settled ?name ~f inputs = all_settled ?name ~pool:P.pool ~f inputs
  end
end
