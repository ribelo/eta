(** Core Effect machinery: frame infrastructure, the [('a, 'err) t] type, and
    basic combinators
    (pure/fail/from_option/bind/map/bind_error/catch_some/timeout/retry). Internal:
    see Effect for the public surface. *)

open Runtime_core

module RObs = Runtime_observability
module P_atomic = Atomic

(* ---------------------------------------------------------------- *)
(* Frame infrastructure                                              *)
(* ---------------------------------------------------------------- *)

type frame = {
  runtime : Obj.t Runtime_core.t;
  error_renderer : (Obj.t -> string);
  fail_key : Runtime_core.Typed_fail.key;
  sw : Runtime_contract.scope;
  interrupt_of_cancel : 'err. exn -> 'err Cause.t;
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

let finalizer_error_pp frame =
  let error_renderer = frame.error_renderer in
  fun fmt err ->
    Format.pp_print_string fmt
      (RObs.render_typed_failure ~error_renderer (Obj.repr err))

let capture_finalizer_cause frame cause =
  Cause.finalizer_of_cause (finalizer_error_pp frame) cause

(* ---------------------------------------------------------------- *)
(* Effect type and basic constructors                                *)
(* ---------------------------------------------------------------- *)

let ok value = Exit.Ok value
let[@cold] [@zero_alloc assume error] error cause = Exit.Error cause
let default_renderer _ = "<typed failure>"
let default_interrupt_of_cancel _ = Cause.interrupt

type ('a, +'err) t =
  | Pure : 'a -> ('a, 'err) t
  | Fail : 'err -> ('a, 'err) t
  | Custom :
      {
        eval : frame -> ('a, 'err) Exit.t;
        leaf_name : string option;
      }
      -> ('a, 'err) t
  (* [Effect.sync] is the universal way to lift ordinary OCaml computation into
     an effect, so it gets its own constructor rather than reusing [Custom].
     [Custom] would need a closure to carry the exception handling and a 3-word
     block to carry an always-[None] [leaf_name]; interpreting [Sync] directly in
     [eval] costs one 2-word block and no closure. *)
  | Sync : (unit -> 'a) -> ('a, 'err) t
  | Sync_frame :
      {
        run : frame -> 'a;
        leaf_name : string option;
      }
      -> ('a, 'err) t
  | Sync_contract :
      {
        value : 'value;
        run : Runtime_contract.t -> 'value -> 'a;
        leaf_name : string option;
      }
      -> ('a, 'err) t
  | Sync_contract2 :
      {
        value1 : 'value1;
        value2 : 'value2;
        run : Runtime_contract.t -> 'value1 -> 'value2 -> 'a;
        leaf_name : string option;
      }
      -> ('a, 'err) t
  | Async :
      {
        register :
          (('a, 'err) Exit.t -> unit) -> (unit, 'err) t option;
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
  (* Like [Sync], this exists to avoid paying a closure plus a [Custom] block per
     construction. [preserve] would allocate a closure capturing both [inner] and
     [handler] and then a [Custom] block to hold it; one node holds the same two
     fields. *)
  | Bind_error :
      {
        inner : ('a, 'err1) t;
        handler : 'err1 -> ('a, 'err2) t;
      }
      -> ('a, 'err2) t

let bind_error_leaf_name = "Effect.bind_error"
let async_leaf_name = "Effect.async"

let leaf_name : type a err. (a, err) t -> string option = function
  | Custom { leaf_name; _ } -> leaf_name
  (* [bind_error] was a named [Custom], and the name is observable through
     [Effect.name] and [describe], so it is reported unchanged. *)
  | Bind_error _ -> Some bind_error_leaf_name
  | Async _ -> Some async_leaf_name
  | Sync_frame { leaf_name; _ } -> leaf_name
  | Sync_contract { leaf_name; _ } -> leaf_name
  | Sync_contract2 { leaf_name; _ } -> leaf_name
  | Pure _ | Fail _ | Map _ | Bind _ | Sync _ -> None

let make ?leaf_name eval =
  Custom { eval; leaf_name }

let preserve ?leaf_name eff (eval) =
  make ?leaf_name eval

let[@inline always] [@zero_alloc opt] exit_to_value frame = function
  | Exit.Ok value -> value
  | Exit.Error cause -> Runtime_core.raise_cause frame.fail_key cause

let[@cold] [@zero_alloc assume error] exit_of_exn frame exn =
  Exit.Error (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn)

let combine_stripped combine causes =
  match List.filter_map Fun.id causes with
  | [] -> None
  | causes -> Some (combine causes)

let rec stripped_uncatchable : type err mapped. err Cause.t -> mapped Cause.t option =
  (* ZIO [catchAll]/[foldZIO] and effect-ts [catch]/[findError] select one
     recoverable [Fail]; they do not traverse a composite cause running one
     recovery effect per leaf. Eta keeps the additional local invariant that
     defects, interruption, and finalizer diagnostics are not caught. If any of
     those uncatchable leaves remain, return them without invoking the handler:
     handler side effects must not run when the operation is still going to
     fail, and old typed failures cannot be preserved across [bind_error]'s new
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
  let interrupt_of_cancel = interrupt_of_cancel internal_cancel in
  let child_frame = { frame with sw; interrupt_of_cancel; finalizers } in
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

type ('a, 'err) async_state =
  | Async_pending
  | Async_registered of (unit, 'err) t option
  | Async_waiting of {
      canceler : (unit, 'err) t option;
      resolver : ('a, 'err) Exit.t Runtime_contract.resolver;
    }
  | Async_resolved of ('a, 'err) Exit.t
  | Async_interrupt_claimed
  | Async_closed

let run_async_canceler eval frame canceler =
  let outcome = ref None in
  let raised = ref None in
  (try
     Runtime_core.with_restoration_forbidden frame.runtime (fun () ->
         frame.runtime.contract.Runtime_contract.protect (fun () ->
             outcome :=
               Some
                 (run_scope_body frame (fun child_frame ->
                      exit_to_value child_frame
                        (eval child_frame canceler)))))
   with exn ->
     match !outcome with
     | Some _ when Runtime_core.is_cancellation frame.runtime.contract exn -> ()
     | Some _ | None -> raised := Some exn);
  let capture cause = capture_finalizer_cause frame cause in
  match (!raised, !outcome) with
  | Some exn, _ ->
      Some
        (capture
           (Runtime_core.cause_of_exn_runtime frame.runtime frame.fail_key exn))
  | None, Some (Exit.Error cause) -> Some (capture cause)
  | None, Some (Exit.Ok ()) -> None
  | None, None ->
      invalid_arg "Effect.async: canceler protection returned no outcome"

let rec eval : type a err. frame -> (a, err) t -> (a, err) Exit.t =
 fun frame -> function
  | Pure value -> ok value
  | Fail err -> error (Cause.Fail err)
  | Custom { eval; _ } -> eval frame
  | Sync f -> (
      try ok (f ()) with
      | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
          raise exn
      | exn -> exit_of_exn frame exn)
  | Sync_frame { run; _ } -> (
      try ok (run frame) with
      | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
          raise exn
      | exn -> exit_of_exn frame exn)
  | Sync_contract { value; run; _ } -> (
      try ok (run frame.runtime.contract value) with
      | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
          raise exn
      | exn -> exit_of_exn frame exn)
  | Sync_contract2 { value1; value2; run; _ } -> (
      try ok (run frame.runtime.contract value1 value2) with
      | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
          raise exn
      | exn -> exit_of_exn frame exn)
  | Async { register } -> eval_async frame register
  | Map { inner; f; _ } -> (
      match eval frame inner with
      | Exit.Ok value -> ok (f value)
      | Exit.Error _ as err -> err)
  | Bind { inner; k; _ } -> (
      match eval frame inner with
      | Exit.Ok value -> eval frame (k value)
      | Exit.Error _ as err -> err)
  | Bind_error { inner; handler } -> (
      match eval frame inner with
      | Exit.Ok value -> ok value
      | Exit.Error cause -> (
          match stripped_uncatchable cause with
          | Some cause -> error cause
          | None -> (
              match first_typed_failure cause with
              | Some err -> eval frame (handler err)
              | None -> invalid_arg "Effect.bind_error: empty composite cause")))
and eval_async : type a err.
    frame ->
    (((a, err) Exit.t -> unit) -> (unit, err) t option) ->
    (a, err) Exit.t =
 fun frame register ->
  let contract = frame.runtime.contract in
  let state = Atomic.make Async_pending in
  let resume exit =
    let resolved = Async_resolved exit in
    let rec claim () =
      let observed = Atomic.get state in
      match observed with
      | Async_pending | Async_registered _ ->
          if not (Atomic.compare_and_set state observed resolved) then claim ()
      | Async_waiting { resolver; _ } ->
          if Atomic.compare_and_set state observed resolved then
            contract.Runtime_contract.resolve_promise resolver exit
          else claim ()
      | Async_resolved _ | Async_interrupt_claimed | Async_closed -> ()
    in
    claim ()
  in
  let rec close () =
    let observed = Atomic.get state in
    match observed with
    | Async_pending | Async_registered _ | Async_waiting _ ->
        if not (Atomic.compare_and_set state observed Async_closed) then close ()
    | Async_resolved _ | Async_interrupt_claimed | Async_closed -> ()
  in
  let rec on_interruption exn =
    let observed = Atomic.get state in
    match observed with
    | Async_pending ->
        if
          Atomic.compare_and_set state observed Async_interrupt_claimed
        then raise exn
        else on_interruption exn
    | Async_registered canceler | Async_waiting { canceler; _ } ->
        if
          Atomic.compare_and_set state observed Async_interrupt_claimed
        then
          match canceler with
          | None -> raise exn
          | Some canceler -> (
              match run_async_canceler eval frame canceler with
              | None -> raise exn
              | Some finalizer ->
                  let reason =
                    match Runtime_core.cancellation_reason contract exn with
                    | Some reason -> reason
                    | None -> assert false
                  in
                  error
                    (Cause.suppressed
                       ~primary:(frame.interrupt_of_cancel reason)
                       ~finalizer))
        else on_interruption exn
    | Async_resolved exit -> exit
    | Async_interrupt_claimed | Async_closed -> raise exn
  in
  try
    let settled_after_race () =
      match Atomic.get state with
      | Async_resolved exit -> exit
      | Async_pending | Async_registered _ | Async_waiting _
      | Async_interrupt_claimed | Async_closed ->
          assert false
    in
    let run () =
      let canceler =
        contract.Runtime_contract.protect (fun () -> register resume)
      in
      match Atomic.get state with
      | Async_resolved exit -> exit
      | Async_pending ->
          let registered = Async_registered canceler in
          if Atomic.compare_and_set state Async_pending registered then
            let #(promise, resolver) =
      contract.Runtime_contract.create_promise ()
            in
            let waiting = Async_waiting { canceler; resolver } in
            if Atomic.compare_and_set state registered waiting then
              contract.Runtime_contract.cancel_sub @@ fun _cancel_context ->
              contract.Runtime_contract.await_promise promise
            else settled_after_race ()
          else settled_after_race ()
      | Async_registered _ | Async_waiting _ | Async_interrupt_claimed
      | Async_closed ->
          assert false
    in
    (try run () with
    | exn when Runtime_core.is_cancellation contract exn ->
        on_interruption exn)
  with
  | exn when Runtime_core.is_cancellation contract exn -> raise exn
  | exn ->
      close ();
      exit_of_exn frame exn

let run_to_exit frame eff =
  try eval frame eff with
  | exn when Runtime_core.is_cancellation frame.runtime.contract exn -> raise exn
  | exn -> exit_of_exn frame exn

let run_to_value frame eff = exit_to_value frame (run_to_exit frame eff)

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
let from_option ~if_none = function Some value -> pure value | None -> fail if_none

let sync_frame ?leaf_name run =
  Sync_frame { run; leaf_name }

let sync_contract ?leaf_name value run =
  Sync_contract { value; run; leaf_name }

let sync_contract2 ?leaf_name value1 value2 run =
  Sync_contract2 { value1; value2; run; leaf_name }

(* Interpreted by [eval]'s [Sync] branch, which carries the same exception
   handling this used to install in a per-construction closure. *)
let sync f = Sync f

let yield = sync_frame (fun frame -> fiber_yield frame)

let async ~register = Async { register }

let never : 'a 'err. ('a, 'err) t =
  Custom
    {
      eval =
        (fun frame ->
          let #(promise, _resolver) =
      frame.runtime.contract.Runtime_contract.create_promise ()
          in
          try ok (frame.runtime.contract.Runtime_contract.await_promise promise)
          with
          | exn when Runtime_core.is_cancellation frame.runtime.contract exn ->
              raise exn
          | exn -> exit_of_exn frame exn);
      leaf_name = Some "Effect.never";
    }

let die_message message = sync (fun () -> failwith message)

(* ---------------------------------------------------------------- *)
(* Combinators                                                       *)
(* ---------------------------------------------------------------- *)

let map (f) eff =
  Map { inner = eff; f }

let bind (k) eff =
  Bind { inner = eff; k }

let ( >>= ) eff (k) = bind k eff
let flatten_result eff = bind from_result eff
let sync_result f = flatten_result (sync f)
let sync_option ~if_none f = bind (from_option ~if_none) (sync f)
let tap (k) eff = bind (fun value -> map (fun _ -> value) (k value)) eff
let seq next self = bind (fun () -> next) self

let concat effects =
  let sequenced = List.fold_left (fun acc eff -> seq eff acc) unit effects in
  make (fun frame -> eval frame sequenced)

let bind_error :
    type a err1 err2. (err1 -> (a, err2) t) -> (a, err1) t -> (a, err2) t =
 fun (handler) eff ->
 match eff with
  | Pure value -> Pure value
  | _ -> Bind_error { inner = eff; handler }

let catch_some (handler) eff =
  match eff with
  | Pure value -> Pure value
  | _ ->
      preserve ~leaf_name:"Effect.catch_some" eff @@ fun frame ->
      match eval frame eff with
      | Exit.Ok value -> ok value
      | Exit.Error cause -> (
          match stripped_uncatchable cause with
          | Some _ -> error cause
          | None -> (
              match first_typed_failure cause with
              | Some err -> (
                  match handler err with
                  | Some recovery -> eval frame recovery
                  | None -> error cause)
              | None -> invalid_arg "Effect.catch_some: empty composite cause"))

let fold ~ok ~error eff =
  bind_error (fun err -> pure (error err)) (map ok eff)

let or_else fallback eff = bind_error (fun _ -> fallback ()) eff
let when_ condition eff =
  if condition then map (fun value -> Some value) eff else pure None

let unless condition eff = when_ (not condition) eff
let when_effect condition eff = bind (fun condition -> when_ condition eff) condition
let unless_effect condition eff =
  bind (fun condition -> unless condition eff) condition

let filter_or_fail predicate ~if_false eff =
  bind (fun value -> if predicate value then pure value else fail (if_false value)) eff

let discard eff = map (fun _ -> ()) eff
let ignore_errors eff = bind_error (fun _ -> unit) (discard eff)
let to_result eff =
  bind_error (fun err -> pure (Error err)) (map (fun value -> Ok value) eff)
let to_option eff = bind_error (fun _ -> pure None) (map (fun value -> Some value) eff)

let to_exit eff =
  preserve ~leaf_name:"Effect.to_exit" eff @@ fun frame ->
  ok
    (try eval frame eff with
    | exn -> exit_of_exn frame exn)

let map_cause_error = Cause.map

let map_error (f) eff =
  preserve ~leaf_name:"Effect.map_error" eff @@ fun frame ->
  match eval frame eff with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause -> error (map_cause_error f cause)

let rec or_die_cause :
    type err outer. frame -> (err -> exn) -> err Cause.t -> outer Cause.t =
 fun frame to_exn -> function
  | Cause.Fail err -> Runtime_core.die_of_exn_runtime frame.runtime (to_exn err)
  | Cause.Die die -> Cause.Die die
  | Cause.Interrupt id -> Cause.Interrupt id
  | Cause.Sequential causes ->
      Cause.Sequential (List.map (or_die_cause frame to_exn) causes)
  | Cause.Concurrent causes ->
      Cause.Concurrent (List.map (or_die_cause frame to_exn) causes)
  | Cause.Finalizer cause -> Cause.Finalizer cause
  | Cause.Suppressed { primary; finalizer } ->
      Cause.Suppressed { primary = or_die_cause frame to_exn primary; finalizer }

let or_die (to_exn) eff =
  match eff with
  | Pure value -> Pure value
  | _ ->
      preserve ~leaf_name:"Effect.or_die" eff @@ fun frame ->
      match eval frame eff with
      | Exit.Ok _ as ok -> ok
      | Exit.Error cause -> error (or_die_cause frame to_exn cause)

let run_observer frame original observer =
  match eval frame observer with
  | Exit.Ok () -> original
  | Exit.Error cause -> error cause

let tap_error (observe) eff =
  preserve ~leaf_name:"Effect.tap_error" eff @@ fun frame ->
  match eval frame eff with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause as original -> (
      match first_typed_failure cause with
      | Some err -> run_observer frame original (observe err)
      | None -> original)

let tap_cause (observe) eff =
  preserve ~leaf_name:"Effect.tap_cause" eff @@ fun frame ->
  match eval frame eff with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause as original -> run_observer frame original (observe cause)

let tap_defect (observe) eff =
  preserve ~leaf_name:"Effect.tap_defect" eff @@ fun frame ->
  match eval frame eff with
  | Exit.Ok _ as ok -> ok
  | Exit.Error cause as original -> (
      match Cause.defects cause with
      | die :: _ -> run_observer frame original (observe die)
      | [] -> original)

let delay duration eff =
  preserve ~leaf_name:"Effect.delay" eff @@ fun frame ->
  let clock = Runtime_core.current_clock frame.runtime in
  clock#sleep duration;
  eval frame eff

let sleep duration =
  sync_frame ~leaf_name:"Effect.sleep" (fun frame ->
      let clock = Runtime_core.current_clock frame.runtime in
      clock#sleep duration)

let now_ms =
  sync_frame ~leaf_name:"Effect.now_ms" (fun frame ->
      let clock = Runtime_core.current_clock frame.runtime in
      clock#now_ms ())
let fresh () = sync_frame (fun frame -> frame.runtime.contract.fresh ())
let fresh_named prefix = fresh () |> map (Printf.sprintf "%s-%d" prefix)

let timed eff =
  preserve ~leaf_name:"Effect.timed" eff @@ fun frame ->
  let clock = Runtime_core.current_clock frame.runtime in
  let started_ms = clock#now_ms () in
  match eval frame eff with
  | Exit.Ok value ->
      let ended_ms = clock#now_ms () in
      ok (Duration.ms (ended_ms - started_ms), value)
  | Exit.Error _ as err -> err

let timeout_as duration ~on_timeout eff =
  preserve ~leaf_name:"Effect.timeout_as" eff @@ fun frame ->
  let clock = Runtime_core.current_clock frame.runtime in
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
         clock#sleep duration;
         timeout_fired := true;
         select timeout_sw `Timeout);
     fiber_fork frame ~sw:timeout_sw (fun () ->
         let _, tracer = Runtime_core.current_tracer frame.runtime in
         let result =
           tracer#with_task_context frame.runtime.contract
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
  preserve ~leaf_name:"Effect.uninterruptible" eff @@ fun frame ->
  let contract = frame.runtime.contract in
  contract.Runtime_contract.with_cancel_mask @@ fun restore ->
  let binding =
    match
      contract.Runtime_contract.local_get
        Runtime_core.cancellation_restoration
    with
    | Some (Runtime_core.Restoration_forbidden _) ->
        Runtime_core.Restoration_forbidden ()
    | Some (Runtime_core.Restore _ | Runtime_core.Restored) | None ->
        Runtime_core.Restore restore
  in
  contract.Runtime_contract.local_with_binding
    Runtime_core.cancellation_restoration binding (fun () -> eval frame eff)

let interruptible eff =
  preserve ~leaf_name:"Effect.interruptible" eff @@ fun frame ->
  let contract = frame.runtime.contract in
  match
    contract.Runtime_contract.local_get Runtime_core.cancellation_restoration
  with
  | None | Some Runtime_core.Restored
  | Some (Runtime_core.Restoration_forbidden _) ->
      eval frame eff
  | Some (Runtime_core.Restore restore) ->
      contract.Runtime_contract.local_with_binding
        Runtime_core.cancellation_restoration Runtime_core.Restored (fun () ->
          restore.Runtime_contract.restore (fun () -> eval frame eff))

let name eff = leaf_name eff

let describe eff =
  let buffer = Buffer.create 128 in
  let line depth text =
    if Buffer.length buffer > 0 then Buffer.add_char buffer '\n';
    Buffer.add_string buffer (String.make (depth * 2) ' ');
    Buffer.add_string buffer text
  in
  let rec walk : type a err. int -> (a, err) t -> unit =
   fun depth -> function
    | Pure _ -> line depth "Pure"
    | Fail _ -> line depth "Fail"
    | Custom { leaf_name = None; _ } -> line depth "Custom"
    (* A [sync] leaf was a [Custom] with no [leaf_name] before it got its own
       constructor, and [describe] is public output, so it keeps rendering the
       same. Renaming it to "Sync" would be a user-visible change. *)
    | Sync _ -> line depth "Custom"
    | Sync_frame { leaf_name = None; _ } -> line depth "Custom"
    | Sync_frame { leaf_name = Some name; _ } ->
        line depth (Printf.sprintf "Custom(%S)" name)
    | Sync_contract { leaf_name = None; _ } -> line depth "Custom"
    | Sync_contract { leaf_name = Some name; _ } ->
        line depth (Printf.sprintf "Custom(%S)" name)
    | Sync_contract2 { leaf_name = None; _ } -> line depth "Custom"
    | Sync_contract2 { leaf_name = Some name; _ } ->
        line depth (Printf.sprintf "Custom(%S)" name)
    | Async _ -> line depth (Printf.sprintf "Custom(%S)" async_leaf_name)
    (* Was a named [Custom]; render identically, and as before do not walk the
       inner effect, which a [Custom] never exposed. *)
    | Bind_error _ -> line depth (Printf.sprintf "Custom(%S)" bind_error_leaf_name)
    | Custom { leaf_name = Some name; _ } ->
        line depth (Printf.sprintf "Custom(%S)" name)
    | Map { inner; _ } ->
        line depth "Map";
        walk (depth + 1) inner
    | Bind { inner; _ } ->
        line depth "Bind";
        walk (depth + 1) inner;
        line (depth + 1) "<bind …>"
  in
  walk 0 eff;
  Buffer.contents buffer
