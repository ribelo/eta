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
let fiberless_frame_key : frame option Domain.DLS.key =
  Domain.DLS.new_key (fun () -> None)

let fiber_get key =
  try Eio.Fiber.get key with Stdlib.Effect.Unhandled _ -> None

let current_frame () =
  match fiber_get frame_key with
  | Some frame -> frame
  | None -> (
      match Domain.DLS.get fiberless_frame_key with
      | Some frame -> (
          match frame.runtime.substrate.fiber_get frame_key with
          | Some frame -> frame
          | None -> frame)
      | None -> failwith "Eta effect requires Runtime.run")

let with_fiberless_frame frame f =
  let previous = Domain.DLS.get fiberless_frame_key in
  Domain.DLS.set fiberless_frame_key (Some frame);
  Fun.protect
    ~finally:(fun () -> Domain.DLS.set fiberless_frame_key previous)
    f

let with_frame frame f =
  frame.runtime.substrate.fiber_with_binding
    ~dls_active:(Option.is_some (Domain.DLS.get fiberless_frame_key))
    ~enter_fiberless:(with_fiberless_frame frame)
    frame_key frame f

let switch_run frame f = frame.runtime.substrate.switch_run f

let switch_fail frame sw exn = frame.runtime.substrate.switch_fail sw exn

let fiber_fork frame ~sw f = frame.runtime.substrate.fiber_fork ~sw f

let fiber_fork_daemon frame ~sw f =
  frame.runtime.substrate.fiber_fork_daemon ~sw f

let fiber_await_cancel frame = frame.runtime.substrate.fiber_await_cancel ()

let fiber_yield frame = frame.runtime.substrate.fiber_yield ()

let cancel_sub frame f = frame.runtime.substrate.cancel_sub f

let cancel_cancel frame cancel_context exn =
  frame.runtime.substrate.cancel_cancel cancel_context exn

let render_error frame err =
  RObs.render_typed_failure ~error_renderer:frame.error_renderer (Obj.repr err)

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
  try with_frame frame effect.eval with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> exit_of_exn frame exn

let run_to_value frame effect = exit_to_value frame (run_to_exit frame effect)

let run_scope_body ?sw frame body =
  let finalizers = ref [] in
  let sw = Option.value sw ~default:frame.sw in
  let child_frame = { frame with sw; finalizers } in
  try
    ok
      (Runtime_core.with_finalizers ~runtime:frame.runtime
         ~fail_key:frame.fail_key
         ~error_renderer:child_frame.error_renderer finalizers (fun () ->
           body child_frame))
  (* Child scopes report cancellation as an Exit so concurrent combinators,
     retry/repeat, and supervisors can compose interruption with finalizers
     uniformly. Root Runtime.run remains the boundary that re-raises plain Eio
     cancellation to callers. *)
  with exn -> exit_of_exn child_frame exn

let run_scope ?sw frame effect =
  run_scope_body ?sw frame (fun child_frame -> run_to_value child_frame effect)

let run_scope_value ?sw frame effect = exit_to_value frame (run_scope ?sw frame effect)

let run_scope_body_value ?sw frame body =
  exit_to_value frame (run_scope_body ?sw frame body)

let pure value = make (fun () -> ok value)
let fail err = make (fun () -> error (Cause.Fail err))
let unit = pure ()
let from_result = function Stdlib.Ok value -> pure value | Stdlib.Error err -> fail err
let sync f =
  make (fun () ->
      try ok (f ()) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> exit_of_exn (current_frame ()) exn)

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

type ('a, 'err) catch_result =
  | Caught of 'a
  | Uncaught of 'err Cause.t

let rec catch_cause handler = function
  | Cause.Fail err -> (
      match (handler err).eval () with
      | Exit.Ok value -> Caught value
      | Exit.Error cause -> Uncaught cause)
  | Cause.Die die -> Uncaught (Cause.Die die)
  | Cause.Interrupt id -> Uncaught (Cause.Interrupt id)
  | Cause.Finalizer cause -> Uncaught (Cause.Finalizer cause)
  | Cause.Sequential causes -> catch_causes Cause.sequential handler causes
  | Cause.Concurrent causes -> catch_causes Cause.concurrent handler causes
  | Cause.Suppressed { primary; finalizer } -> (
      match catch_cause handler primary with
      | Caught _ -> Uncaught (Cause.finalizer finalizer)
      | Uncaught primary ->
          Uncaught (Cause.suppressed ~primary ~finalizer))

and catch_causes combine handler causes =
  (* [catch] returns one value, while a composite cause may contain several
     typed failures. Eta therefore uses the first handled branch as the
     recovery value only when every branch was handled; any uncaught branch
     keeps the operation failed and is recombined with the original shape. *)
  let value, uncaught =
    List.fold_left
      (fun (value, uncaught) cause ->
        match catch_cause handler cause with
        | Caught caught ->
            let value =
              match value with Some _ -> value | None -> Some caught
            in
            (value, uncaught)
        | Uncaught cause -> (value, cause :: uncaught))
      (None, []) causes
  in
  match (value, List.rev uncaught) with
  | Some value, [] -> Caught value
  | _, cause :: causes -> Uncaught (combine (cause :: causes))
  | None, [] -> invalid_arg "Effect.catch: empty composite cause"

let catch handler effect =
  preserve effect @@ fun () ->
  match effect.eval () with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause -> (
      match catch_cause handler cause with
      | Caught value -> ok value
      | Uncaught cause -> error cause)

let map_cause_error = Cause.map

let render_cause_error frame cause =
  Cause.finalizer_of_cause (render_error frame) cause

let finalizer_cause frame cause = Cause.finalizer (render_cause_error frame cause)

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
        error
          (Cause.suppressed ~primary:(Cause.Fail err)
             ~finalizer:(render_cause_error frame finalizer)))
  | Exit.Error _ as err -> err

let delay duration effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  frame.runtime.sleep duration;
  effect.eval ()

let timeout_as duration ~on_timeout effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let body_result = ref None in
  let timeout_fired = ref false in
  let winner = ref None in
  let exception Timeout_selected in
  let select sw selected =
    match !winner with
    | Some _ -> ()
    | None ->
        winner := Some selected;
        switch_fail frame sw Timeout_selected;
        fiber_await_cancel frame
  in
  (try
     switch_run frame @@ fun timeout_sw ->
     fiber_fork frame ~sw:timeout_sw (fun () ->
         frame.runtime.sleep duration;
         timeout_fired := true;
         select timeout_sw `Timeout);
     fiber_fork frame ~sw:timeout_sw (fun () ->
         let result =
           frame.runtime.tracer#with_fiber_context @@ fun () ->
           run_scope ~sw:timeout_sw frame effect
         in
         body_result := Some result;
         select timeout_sw `Body);
     fiber_await_cancel frame
   with Timeout_selected -> ());
  match (!winner, !timeout_fired, !body_result) with
  | Some `Body, _, Some result -> result
  | Some `Timeout, true, Some (Exit.Ok _ as result) ->
      (* Timeout cancellation waits for body cleanup. If the body reports a
         successful result during that required cleanup, it had already
         committed a value before the timeout could safely discard it. *)
      result
  | Some `Timeout, true, Some (Exit.Error cause)
    when not (Cause.is_interrupt_only cause) ->
      error (Cause.concurrent [ Cause.Fail on_timeout; cause ])
  | Some `Timeout, _, _ -> error (Cause.Fail on_timeout)
  | None, true, _ -> error (Cause.Fail on_timeout)
  | None, false, Some result -> result
  | None, false, None -> error Cause.interrupt
  | Some `Body, _, None -> error Cause.interrupt

let timeout duration effect = timeout_as duration ~on_timeout:`Timeout effect

let uninterruptible effect =
  preserve effect @@ fun () -> Runtime_core.cancel_protect (fun () -> effect.eval ())

let repeat schedule effect =
  preserve effect @@ fun () ->
  let frame = current_frame () in
  let run_iteration () =
    run_scope_value frame effect
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
  let run_attempt () = run_scope frame effect in
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
