(** Off-pool island execution for CPU-bound or non-Eio workloads. Internal: see
    Effect for the public surface. *)

open Effect_core

let submit_wait frame name f =
  let pool = Lazy.force frame.runtime.default_island_wait_pool in
  Blocking_runtime.submit ~sw:frame.runtime.outer_sw
    ~emit:(Runtime_core.emit_blocking_event frame.runtime)
    pool ("island.wait." ^ name) f

let island ?(name = "island") f input =
  make ~names:[ name ] @@ fun () ->
  let frame = current_frame () in
  try
    let pool = Runtime_core.island_pool frame.runtime None in
    ok (submit_wait frame name (fun () -> Island_runtime.submit name pool f input))
  with exn -> exit_of_exn frame exn

module Island = struct
  type worker_die = Island_runtime.worker_die = {
    kind : string;
    message : string;
    backtrace : string option;
  }

  type ('a : immutable_data, 'e : immutable_data) settled =
    ('a, 'e) Island_runtime.settled =
    | Ok of 'a
    | Error of 'e
    | Worker_died of worker_die

  type pool = Island_runtime.pool
  module Pool = Island_runtime.Pool

  let map ?(name = "island.map") ?pool ~f inputs =
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    try
      let pool = Runtime_core.island_pool frame.runtime pool in
      ok
        (submit_wait frame name (fun () ->
             Island_runtime.submit_map name pool f inputs))
    with exn -> exit_of_exn frame exn

  let map_result ?(name = "island.map_result") ?pool ~f inputs =
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    try
      let pool = Runtime_core.island_pool frame.runtime pool in
      ok
        (submit_wait frame name (fun () ->
             Island_runtime.submit_map_result name pool f inputs))
    with exn -> exit_of_exn frame exn

  let all_settled ?(name = "island.all_settled") ?pool ~f inputs =
    make ~names:[ name ] @@ fun () ->
    let frame = current_frame () in
    try
      let pool = Runtime_core.island_pool frame.runtime pool in
      ok
        (submit_wait frame name (fun () ->
             Island_runtime.submit_all_settled pool f inputs))
    with exn -> exit_of_exn frame exn
end
