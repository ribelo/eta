(** Public Effect implementation. *)

open Effect_core

include Effect_core
include Effect_resource
include Effect_concurrent
include Effect_observability
include Effect_supervisor_scope
include Effect_schedule

let metric_timer ?description ?(unit_ = "ms") ?attrs ~name ~boundaries eff =
  let timer =
    now_ms
    |> bind (fun started ->
           on_exit
             (fun _exit ->
               now_ms
               |> bind (fun ended ->
                      let elapsed_ms = max 0 (ended - started) in
                      metric_histogram ?description ~unit_ ?attrs ~name
                        ~boundaries (float_of_int elapsed_ms)))
             eff)
  in
  preserve ~leaf_name:"Effect.metric_timer" timer (fun frame -> eval frame timer)
