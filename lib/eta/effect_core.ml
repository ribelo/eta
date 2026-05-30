(** Core Effect machinery: frame infrastructure, the [('a, 'err) t] type, and
    basic combinators (pure/fail/bind/map/catch/timeout/retry). Internal: see
    Effect for the public surface. *)

open Runtime_core

module RObs = Runtime_observability
module Sch = Schedule
module P_atomic = Portable.Atomic

(* ---------------------------------------------------------------- *)
(* Frame infrastructure                                              *)
(* ---------------------------------------------------------------- *)

type frame = {
  runtime : Obj.t Runtime_core.t;
  error_renderer : Obj.t -> string;
  fail_key : Runtime_core.Typed_fail.key;
  sw : Eio.Switch.t;
  finalizers : (unit -> unit) list ref;
}

let frame_key : frame Eio.Fiber.key = Eio.Fiber.create_key ()
let fiberless_frame = ref None

let fiber_get key =
  try Eio.Fiber.get key with Stdlib.Effect.Unhandled _ -> None

let host_fiber_get frame key =
  match frame.runtime.host_eio with
  | None -> None
  | Some host -> (
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      try Fiber.get key with Stdlib.Effect.Unhandled _ -> None)

let has_fiber_context () =
  try
    ignore (Eio.Fiber.get frame_key);
    true
  with Stdlib.Effect.Unhandled _ -> false

let current_frame () =
  match fiber_get frame_key with
  | Some frame -> frame
  | None -> (
      match !fiberless_frame with
      | Some frame -> (
          match host_fiber_get frame frame_key with
          | Some frame -> frame
          | None -> frame)
      | None -> failwith "Eta effect requires Runtime.run")

let with_fiberless_frame frame f =
  let previous = !fiberless_frame in
  fiberless_frame := Some frame;
  Fun.protect ~finally:(fun () -> fiberless_frame := previous) f

let with_frame frame f =
  match frame.runtime.host_eio with
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      let bind () = Fiber.with_binding frame_key frame f in
      if Option.is_some !fiberless_frame then bind ()
      else with_fiberless_frame frame bind
  | None ->
      if has_fiber_context () then Eio.Fiber.with_binding frame_key frame f
      else with_fiberless_frame frame f

let switch_run frame f =
  match frame.runtime.host_eio with
  | None -> Eio.Switch.run f
  | Some host ->
      let module Switch = (val Host_eio.switch host : Host_eio.SWITCH) in
      Switch.run f

let switch_fail frame sw exn =
  match frame.runtime.host_eio with
  | None -> Eio.Switch.fail sw exn
  | Some host ->
      let module Switch = (val Host_eio.switch host : Host_eio.SWITCH) in
      Switch.fail sw exn

let fiber_first frame left right =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.first left right
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.first left right

let fiber_fork frame ~sw f =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.fork ~sw f
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.fork ~sw f

let fiber_fork_daemon frame ~sw f =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.fork_daemon ~sw f
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.fork_daemon ~sw f

let fiber_await_cancel frame =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.await_cancel ()
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.await_cancel ()

let fiber_yield frame =
  match frame.runtime.host_eio with
  | None -> Eio.Fiber.yield ()
  | Some host ->
      let module Fiber = (val Host_eio.fiber host : Host_eio.FIBER) in
      Fiber.yield ()

let cancel_sub frame f =
  match frame.runtime.host_eio with
  | None -> Eio.Cancel.sub f
  | Some host ->
      let module Cancel = (val Host_eio.cancel host : Host_eio.CANCEL) in
      Cancel.sub f

let cancel_cancel frame cancel_context exn =
  match frame.runtime.host_eio with
  | None -> Eio.Cancel.cancel cancel_context exn
  | Some host ->
      let module Cancel = (val Host_eio.cancel host : Host_eio.CANCEL) in
      Cancel.cancel cancel_context exn

let render_error frame err = frame.error_renderer (Obj.repr err)

(* ---------------------------------------------------------------- *)
(* Effect type and basic constructors                                *)
(* ---------------------------------------------------------------- *)

type ('a, 'err) t = {
  eval : unit -> ('a, 'err) Exit.t;
  leaf_name : string option;
  names : string list;
}

let make ?leaf_name ?(names = []) eval = { eval; leaf_name; names }
let preserve effect eval = make ~names:effect.names eval
let concat_names effects = List.concat_map (fun effect -> effect.names) effects
let with_names names effect = { effect with names }

let ok value = Exit.Ok value
let[@cold] [@zero_alloc assume error] error cause = Exit.Error cause
let default_renderer _ = "<typed failure>"

let[@inline always] [@zero_alloc opt] exit_to_value frame = function
  | Exit.Ok value -> value
  | Exit.Error cause -> Runtime_core.raise_cause frame.fail_key cause

let[@cold] [@zero_alloc assume error] exit_of_exn frame exn =
  Exit.Error (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn)

let run_to_exit frame effect =
  try with_frame frame effect.eval with exn -> exit_of_exn frame exn

let run_to_value frame effect = exit_to_value frame (run_to_exit frame effect)

let pure value = make (fun () -> ok value)
let fail err = make (fun () -> error (Cause.Fail err))
let unit = pure ()
let from_result = function Stdlib.Ok value -> pure value | Stdlib.Error err -> fail err
let sync f = make (fun () -> try ok (f ()) with exn -> exit_of_exn (current_frame ()) exn)

(* ---------------------------------------------------------------- *)
(* Combinators                                                       *)
(* ---------------------------------------------------------------- *)

let map f effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok value -> ok (f value)
  | Exit.Error _ as err -> err

let bind k effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok value -> (k value).eval ()
  | Exit.Error _ as err -> err

let ( >>= ) effect k = bind k effect
let tap k effect = bind (fun value -> map (fun () -> value) (k value)) effect
let seq next self = bind (fun () -> next) self

let concat effects =
  with_names (concat_names effects)
    (List.fold_left (fun acc effect -> seq effect acc) unit effects)

let rec find_fail = function
  | Cause.Fail err -> Some err
  | Cause.Die _ | Cause.Interrupt _ -> None
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.find_map find_fail causes
  | Cause.Suppressed { primary; finalizer } -> (
      match find_fail primary with
      | Some _ as found -> found
      | None -> find_fail finalizer)

let catch handler effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause -> (
      match find_fail cause with
      | Some err -> (handler err).eval ()
      | None -> error (Obj.magic cause))

let rec map_cause_error f = function
  | Cause.Fail err -> Cause.Fail (f err)
  | Cause.Die die -> Cause.Die die
  | Cause.Interrupt id -> Cause.Interrupt id
  | Cause.Sequential causes -> Cause.Sequential (List.map (map_cause_error f) causes)
  | Cause.Concurrent causes -> Cause.Concurrent (List.map (map_cause_error f) causes)
  | Cause.Suppressed { primary; finalizer } ->
      Cause.Suppressed
        {
          primary = map_cause_error f primary;
          finalizer = map_cause_error f finalizer;
        }

let map_error f effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause -> error (map_cause_error f cause)

let tap_error observe effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error (Cause.Fail err) as original -> (
      try
        observe err;
        original
      with exn ->
        let finalizer =
          Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn
        in
        error (Cause.suppressed ~primary:(Cause.Fail err) ~finalizer))
  | Exit.Error _ as err -> err

let delay duration effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  frame.runtime.sleep duration;
  effect.eval ()

let timeout_as duration ~on_timeout effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let token = Runtime_core.Typed_fail.int (Runtime_core.Typed_fail.fresh ()) in
  try
    ok
      (fiber_first frame
         (fun () ->
           frame.runtime.sleep duration;
           raise (Runtime_core.Timeout_as_fired token))
         (fun () -> run_to_value frame effect))
  with exn ->
    if
      Runtime_core.has_timeout_as token exn
      && Runtime_core.only_timeout_as_or_interrupt token exn
    then error (Cause.Fail on_timeout)
    else
      error
        (Runtime_core.cause_of_timeout_as_exn frame.runtime frame.fail_key token
           on_timeout exn)

let timeout duration effect = timeout_as duration ~on_timeout:`Timeout effect

let uninterruptible effect =
  preserve effect @@ fun () -> Runtime_core.cancel_protect (fun () -> effect.eval ())

let repeat schedule effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let run_iteration () =
    let finalizers = ref [] in
    let iteration_frame = { frame with finalizers } in
    Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
      finalizers (fun () -> run_to_value iteration_frame effect)
  in
  try
    run_iteration ();
    let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
    let continue = ref true in
    while !continue do
      match Sch.next !driver with
      | None -> continue := false
      | Some (duration, next_driver) ->
          driver := next_driver;
          frame.runtime.sleep duration;
          run_iteration ()
    done;
    ok ()
  with exn -> exit_of_exn frame exn

let retry schedule predicate effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
  let run_attempt () =
    let finalizers = ref [] in
    let attempt_frame = { frame with finalizers } in
    try
      ok
        (Runtime_core.with_finalizers ~runtime:frame.runtime
           ~fail_key:frame.fail_key finalizers (fun () ->
             run_to_value attempt_frame effect))
    with exn -> exit_of_exn attempt_frame exn
  in
  let rec loop () =
    match run_attempt () with
    | Exit.Ok _ as ok -> ok
    | Exit.Error (Cause.Fail err) when predicate err -> (
        match Sch.next !driver with
        | Some (duration, next_driver) ->
            driver := next_driver;
            frame.runtime.sleep duration;
            loop ()
        | None -> error (Cause.Fail err))
    | Exit.Error _ as err -> err
  in
  loop ()

let name effect = effect.leaf_name
let collect_names effect = effect.names
