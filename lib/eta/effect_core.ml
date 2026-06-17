(** Core Effect machinery: frame infrastructure, the [('a, 'err) t] type, and
    basic combinators (pure/fail/bind/map/catch/timeout/retry). Internal: see
    Effect for the public surface. *)

open Runtime_core

module RObs = Runtime_observability
module Sch = Schedule
module P_atomic = Atomic

(* ---------------------------------------------------------------- *)
(* Frame infrastructure                                              *)
(* ---------------------------------------------------------------- *)

type frame = {
  runtime : Obj.t Runtime_core.t;
  error_renderer : (Obj.t -> string);
  fail_key : Runtime_core.Typed_fail.key;
  sw : Runtime_contract.scope;
  finalizers : (unit -> unit) list ref;
}

let switch_run frame (f) =
  frame.runtime.contract.Runtime_contract.run_scope f

let switch_fail frame sw exn =
  frame.runtime.contract.Runtime_contract.fail_scope sw exn

let fiber_fork frame ~sw (f) =
  frame.runtime.contract.Runtime_contract.fork sw f

let fiber_fork_daemon frame ~sw f =
  frame.runtime.contract.Runtime_contract.fork_daemon sw f

let fiber_await_cancel frame =
  frame.runtime.contract.Runtime_contract.await_cancel ()

let fiber_yield frame =
  frame.runtime.contract.Runtime_contract.yield ()

let cancel_sub frame (f) =
  frame.runtime.contract.Runtime_contract.cancel_sub f

let cancel_cancel frame cancel_context exn =
  frame.runtime.contract.Runtime_contract.cancel cancel_context exn

let render_error frame err =
  RObs.render_typed_failure ~error_renderer:frame.error_renderer (Obj.repr err)

(* ---------------------------------------------------------------- *)
(* Effect type and basic constructors                                *)
(* ---------------------------------------------------------------- *)

let ok value = Exit.Ok value
let[@cold] [@zero_alloc assume error] error cause = Exit.Error cause
let default_renderer _ = "<typed failure>"

type ('a, +'err) t =
  | Pure : 'a -> ('a, 'err) t
  | Fail : 'err -> ('a, 'err) t
  | Custom :
      {
        eval : frame -> ('a, 'err) Exit.t;
        leaf_name : string option;
        names : string list;
      }
      -> ('a, 'err) t
  | Map :
      {
        inner : ('a, 'err) t;
        f : 'a -> 'b;
      }
      -> ('b, 'err) t
  | Bind :
      {
        inner : ('a, 'err) t;
        k : 'a -> ('b, 'err) t;
      }
      -> ('b, 'err) t

let rec names : type a err. (a, err) t -> string list = function
  | Pure _ | Fail _ -> []
  | Custom { names; _ } -> names
  | Map { inner; _ } -> names inner
  | Bind { inner; _ } -> names inner

let leaf_name : type a err. (a, err) t -> string option = function
  | Custom { leaf_name; _ } -> leaf_name
  | Pure _ | Fail _ | Map _ | Bind _ -> None

let make ?leaf_name ?(names = []) eval = Custom { eval; leaf_name; names }
let preserve eff (eval) = make ~names:(names eff) eval
let concat_names effects = List.concat_map names effects

let[@inline always] [@zero_alloc opt] exit_to_value frame = function
  | Exit.Ok value -> value
  | Exit.Error cause -> Runtime_core.raise_cause frame.fail_key cause

let[@cold] [@zero_alloc assume error] exit_of_exn frame exn =
  Exit.Error (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn)

let rec eval : type a err. frame -> (a, err) t -> (a, err) Exit.t =
 fun frame -> function
  | Pure value -> ok value
  | Fail err -> error (Cause.Fail err)
  | Custom { eval; _ } -> eval frame
  | Map { inner; f; _ } -> (
      match eval frame inner with
      | Exit.Ok value -> ok (f value)
      | Exit.Error _ as err -> err)
  | Bind { inner; k; _ } -> (
      match eval frame inner with
      | Exit.Ok value -> eval frame (k value)
      | Exit.Error _ as err -> err)

let with_names names eff =
  match eff with
  | Custom custom -> Custom { custom with names }
  | Pure _ | Fail _ | Map _ | Bind _ -> make ~names (fun frame -> eval frame eff)

let run_to_exit frame eff =
  try eval frame eff with
  | exn when Runtime_core.is_cancellation frame.runtime.contract exn -> raise exn
  | exn -> exit_of_exn frame exn

let run_to_value frame eff = exit_to_value frame (run_to_exit frame eff)

type internal_cancel = {
  interrupt_id : Cause.interrupt_id;
  matches_cancel : exn -> bool;
}

let interrupt_of_cancel = function
  | Some { interrupt_id; matches_cancel } ->
      fun reason ->
        if matches_cancel reason then Cause.interrupt_with_id interrupt_id
        else Cause.interrupt
  | None -> fun _ -> Cause.interrupt

let run_scope_body ?sw ?internal_cancel frame (body) =
  let finalizers = ref [] in
  let sw = Option.value sw ~default:frame.sw in
  let child_frame = { frame with sw; finalizers } in
  let interrupt_of_cancel = interrupt_of_cancel internal_cancel in
  try
    ok
      (Runtime_core.with_finalizers ~runtime:frame.runtime
         ~interrupt_of_cancel
         ~fail_key:frame.fail_key
         ~error_renderer:child_frame.error_renderer finalizers (fun () ->
           body child_frame))
  (* Child scopes report cancellation as an Exit so concurrent combinators,
     retry/repeat, and supervisors can compose interruption with finalizers
     uniformly. Root Runtime.run remains the boundary that re-raises plain
     runtime cancellation to callers. *)
  with
  | exn -> (
      match Runtime_core.cancellation_reason frame.runtime.contract exn with
      | Some reason -> error (interrupt_of_cancel reason)
      | None -> exit_of_exn child_frame exn)

let run_scope ?sw ?internal_cancel frame eff =
  run_scope_body ?sw ?internal_cancel frame (fun child_frame ->
      run_to_value child_frame eff)

let run_scope_value ?sw frame eff = exit_to_value frame (run_scope ?sw frame eff)

let run_scope_body_value ?sw frame body =
  exit_to_value frame (run_scope_body ?sw frame body)

let pure value = Pure value
let fail err = Fail err
let unit = pure ()
let from_result = function Stdlib.Ok value -> pure value | Stdlib.Error err -> fail err

let sync_frame f =
  make (fun frame ->
      try ok (f frame) with
      | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
          raise exn
      | exn -> exit_of_exn frame exn)

let sync f = sync_frame (fun _frame -> f ())
let yield = sync_frame (fun frame -> fiber_yield frame)

(* ---------------------------------------------------------------- *)
(* Combinators                                                       *)
(* ---------------------------------------------------------------- *)

let map (f) eff =
  Map { inner = eff; f }

let bind (k) eff =
  Bind { inner = eff; k }

let ( >>= ) eff (k) = bind k eff
let flatten_result eff = bind from_result eff
let tap (k) eff = bind (fun value -> map (fun _ -> value) (k value)) eff
let seq next self = bind (fun () -> next) self

let concat effects =
  with_names (concat_names effects)
    (List.fold_left (fun acc eff -> seq eff acc) unit effects)

let combine_stripped combine causes =
  match List.filter_map Fun.id causes with
  | [] -> None
  | causes -> Some (combine causes)

let rec stripped_uncatchable : type err mapped. err Cause.t -> mapped Cause.t option =
  (* ZIO [catchAll]/[foldZIO] and eff-ts [catch]/[findError] select one
     recoverable [Fail]; they do not traverse a composite cause running one
     recovery eff per leaf. Eta keeps the additional local invariant that
     defects, interruption, and finalizer diagnostics are not caught. If any of
     those uncatchable leaves remain, return them without invoking the handler:
     handler side effects must not run when the operation is still going to
     fail, and old typed failures cannot be preserved across [catch]'s new
     error type without running the handler. *)
  function
  | Cause.Fail _ -> None
  | Cause.Die die -> Some (Cause.Die die)
  | Cause.Interrupt id -> Some (Cause.Interrupt id)
  | Cause.Finalizer cause -> Some (Cause.Finalizer cause)
  | Cause.Sequential causes ->
      combine_stripped Cause.sequential (List.map stripped_uncatchable causes)
  | Cause.Concurrent causes ->
      combine_stripped Cause.concurrent (List.map stripped_uncatchable causes)
  | Cause.Suppressed { primary; finalizer } -> (
      match stripped_uncatchable primary with
      | None -> Some (Cause.finalizer finalizer)
      | Some primary -> Some (Cause.suppressed ~primary ~finalizer))

let rec first_typed_failure : type err. err Cause.t -> err option = function
  | Cause.Fail err -> Some err
  | Cause.Sequential causes | Cause.Concurrent causes ->
      List.find_map first_typed_failure causes
  | Cause.Suppressed { primary; _ } -> first_typed_failure primary
  | Cause.Die _ | Cause.Interrupt _ | Cause.Finalizer _ -> None

let catch :
    type a err1 err2. (err1 -> (a, err2) t) -> (a, err1) t -> (a, err2) t =
 fun (handler) eff ->
 match eff with
  | Pure value -> Pure value
  | _ ->
      preserve eff @@ fun frame ->
      match eval frame eff with
      | Exit.Ok value -> ok value
      | Exit.Error cause -> (
          match stripped_uncatchable cause with
          | Some cause -> error cause
          | None -> (
              match first_typed_failure cause with
              | Some err -> eval frame (handler err)
              | None -> invalid_arg "Effect.catch: empty composite cause"))

let recover (handler) eff = catch (fun err -> pure (handler err)) eff
let ignore_errors eff = catch (fun _ -> unit) eff
let result eff = catch (fun err -> pure (Error err)) (map (fun value -> Ok value) eff)

let map_cause_error = Cause.map

let render_cause_error frame cause =
  Cause.finalizer_of_cause (render_error frame) cause

let finalizer_cause frame cause = Cause.finalizer (render_cause_error frame cause)

let map_error (f) eff =
  preserve eff @@ fun frame ->
  match eval frame eff with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause -> error (map_cause_error f cause)

let tap_error (observe) eff =
  preserve eff @@ fun frame ->
  match eval frame eff with
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

let delay duration eff =
  preserve eff @@ fun frame ->
  frame.runtime.sleep duration;
  eval frame eff

let timeout_as duration ~on_timeout eff =
  preserve eff @@ fun frame ->
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
           frame.runtime.tracer#with_task_context frame.runtime.contract
           @@ fun () ->
           run_scope ~sw:timeout_sw frame eff
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

let timeout duration eff = timeout_as duration ~on_timeout:`Timeout eff

let uninterruptible eff =
  preserve eff @@ fun frame ->
  frame.runtime.contract.Runtime_contract.protect (fun () -> eval frame eff)

let repeat schedule eff =
  preserve eff @@ fun frame ->
  let run_iteration () =
    run_scope_value frame eff
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

let retry schedule (predicate) eff =
  preserve eff @@ fun frame ->
  let driver = ref (Sch.start ~random:frame.runtime.random schedule) in
  let run_attempt () = run_scope frame eff in
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

let name eff = leaf_name eff
let collect_names eff = names eff
