module Update = struct
  type 'a t =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  let delivered_value = function
    | Initialized value -> value
    | Changed { new_value; _ } -> new_value
end

module Delivery_handle = struct
  type ('token, 'update, 'after_ack) t = {
    token : 'token;
    update : 'update;
    current_token :
      'error. unit -> ('token option, 'error) Eta.Effect.t;
    acknowledge_sent :
      'error. 'token -> 'update -> (unit, 'error) Eta.Effect.t;
    acknowledge_drop :
      'error.
      after_ack:'after_ack list ->
      'token ->
      'update ->
      (unit, 'error) Eta.Effect.t;
  }

  let create :
      type token update after_ack.
      token:token ->
      update:update ->
      current_token:
        ('error. unit -> (token option, 'error) Eta.Effect.t) ->
      acknowledge_sent:
        ('error. token -> update -> (unit, 'error) Eta.Effect.t) ->
      acknowledge_drop:
        ('error.
         after_ack:after_ack list ->
         token ->
         update ->
         (unit, 'error) Eta.Effect.t) ->
      (token, update, after_ack) t =
   fun ~token ~update ~current_token ~acknowledge_sent ~acknowledge_drop ->
    { token; update; current_token; acknowledge_sent; acknowledge_drop }

  let token handle = handle.token
  let update handle = handle.update
  let current_token handle = handle.current_token
  let acknowledge_sent handle = handle.acknowledge_sent
  let acknowledge_drop handle = handle.acknowledge_drop
end

module Value = struct
  type 'a t =
    | Uninitialized
    | Current of 'a
    | Failed_without_current

  let uninitialized = Uninitialized
  let current value = Current value

  let mark_failed_without_current = function
    | Uninitialized -> Failed_without_current
    | Current _ | Failed_without_current as value -> value

  let read = function
    | Current value -> Ok value
    | Failed_without_current -> Error `No_current_value
    | Uninitialized -> Error `Uninitialized_observer

  let unsafe_read_exn = function
    | Current value -> value
    | Uninitialized | Failed_without_current ->
        invalid_arg "Eta_signal observer is not initialized"

  let label = function
    | Uninitialized -> "uninitialized"
    | Current _ -> "current"
    | Failed_without_current -> "failed_without_current"
end

module Lifecycle = struct
  type finish_reason =
    | Finish_disposed
    | Finish_invalid_scope

  type ('live, 'value) t =
    | Registering of 'live
    | Active of 'live
    | Disposed of 'value
    | Invalid_scope of 'value

  type ('live, 'value) finish = {
    state : ('live, 'value) t;
    hook_live : 'live option;
    remove : bool;
  }

  let live = function
    | Registering live | Active live -> Some live
    | Disposed _ | Invalid_scope _ -> None

  let active_live = function
    | Active live -> Some live
    | Registering _ | Disposed _ | Invalid_scope _ -> None

  let active = function
    | Active _ -> true
    | Registering _ | Disposed _ | Invalid_scope _ -> false

  let demands = function
    | Registering _ | Active _ -> true
    | Disposed _ | Invalid_scope _ -> false

  let invalid_scope = function
    | Invalid_scope _ -> true
    | Registering _ | Active _ | Disposed _ -> false

  let diagnostic_visible ~include_invalid = function
    | Active _ -> true
    | Invalid_scope _ -> include_invalid
    | Registering _ | Disposed _ -> false

  let label = function
    | Registering _ -> "registering"
    | Active _ -> "active"
    | Disposed _ -> "disposed"
    | Invalid_scope _ -> "invalid_scope"

  let activate = function
    | Registering live -> Ok (Active live)
    | Active _ as state -> Ok state
    | Disposed _ | Invalid_scope _ -> Error `Invalid_scope

  let finish ~value_of_live reason state =
    match (state, reason) with
    | Registering live, Finish_disposed | Active live, Finish_disposed ->
        {
          state = Disposed (value_of_live live);
          hook_live = Some live;
          remove = true;
        }
    | Registering live, Finish_invalid_scope
    | Active live, Finish_invalid_scope ->
        {
          state = Invalid_scope (value_of_live live);
          hook_live = Some live;
          remove = false;
        }
    | Invalid_scope value, Finish_disposed ->
        { state = Disposed value; hook_live = None; remove = true }
    | Disposed _, _ | Invalid_scope _, Finish_invalid_scope ->
        { state; hook_live = None; remove = false }

  let read_value ~value_of_live = function
    | Registering _ -> Error `Uninitialized_observer
    | Disposed _ -> Error `Disposed_observer
    | Invalid_scope _ -> Error `Invalid_scope
    | Active live -> Value.read (value_of_live live)

  let unsafe_read_value_exn ~value_of_live = function
    | Registering _ ->
        invalid_arg "Eta_signal observer registration has not completed"
    | Disposed _ ->
        invalid_arg "Eta_signal observer is disposed"
    | Invalid_scope _ ->
        invalid_arg "Eta_signal observer scope is invalid"
    | Active live -> Value.unsafe_read_exn (value_of_live live)
end

module Delivery = struct
  type token = int

  type ('a, 'after_ack) t =
    | Observer_never_delivered
    | Observer_delivered of 'a
    | Observer_delivery_pending of token * 'a Update.t * 'after_ack list
    | Observer_delivery_running of token * 'a Update.t * 'after_ack list

  type ('a, 'after_ack) finish =
    | Finish_acknowledged of ('a, 'after_ack) t * 'after_ack list
    | Finish_released of ('a, 'after_ack) t

  let base = function
    | Observer_never_delivered -> None
    | Observer_delivered value -> Some value
    | Observer_delivery_pending (_, Initialized _, _) -> None
    | Observer_delivery_pending (_, Changed { old_value; _ }, _) ->
        Some old_value
    | Observer_delivery_running (_, Initialized _, _) -> None
    | Observer_delivery_running (_, Changed { old_value; _ }, _) ->
        Some old_value

  let pending = function
    | Observer_delivery_pending _ | Observer_delivery_running _ -> true
    | Observer_never_delivered | Observer_delivered _ -> false

  let pending_state ~token update =
    Observer_delivery_pending (token, update, [])

  let acknowledge ~token ~update ~after_ack state =
    match state with
    | ( Observer_delivery_pending (pending_token, _, stored_after_ack)
      | Observer_delivery_running (pending_token, _, stored_after_ack) )
      when pending_token = token ->
        let actions = List.rev_append after_ack stored_after_ack in
        Some (Observer_delivered (Update.delivered_value update), actions)
    | Observer_never_delivered | Observer_delivered _
    | Observer_delivery_pending _ | Observer_delivery_running _ ->
        None

  let claim ~token = function
    | Observer_delivery_pending (pending_token, update, after_ack)
      when pending_token = token ->
        Some (Observer_delivery_running (pending_token, update, after_ack))
    | Observer_never_delivered | Observer_delivered _
    | Observer_delivery_pending _ | Observer_delivery_running _ ->
        None

  let release ~token = function
    | Observer_delivery_running (running_token, update, after_ack)
      when running_token = token ->
        Some (Observer_delivery_pending (token, update, after_ack))
    | Observer_never_delivered | Observer_delivered _
    | Observer_delivery_pending _ | Observer_delivery_running _ ->
        None

  let finish_running ~token ~update ~delivered ~after_ack state =
    if delivered then
      match acknowledge ~token ~update ~after_ack state with
      | Some (state, after_ack) -> Some (Finish_acknowledged (state, after_ack))
      | None -> None
    else
      match release ~token state with
      | Some state -> Some (Finish_released state)
      | None -> None

  let running_token = function
    | Observer_delivery_running (token, _, _) -> Some token
    | Observer_never_delivered | Observer_delivered _
    | Observer_delivery_pending _ ->
        None

  let running_token_matches ~token state =
    match running_token state with
    | Some running_token -> running_token = token
    | None -> false

  let label = function
    | Observer_never_delivered -> "never_delivered"
    | Observer_delivered _ -> "delivered"
    | Observer_delivery_pending _ -> "pending"
    | Observer_delivery_running _ -> "running"
end

module Delivery_runner = struct
  type ('event, 'callback, 'error) t = {
    active : 'event -> (bool, 'error) Eta.Effect.t;
    claim : 'event -> (bool, 'error) Eta.Effect.t;
    after_claim : unit -> (unit, 'error) Eta.Effect.t;
    construct : 'event -> ('callback option, 'error) Eta.Effect.t;
    run_callback : 'event -> 'callback -> (unit, 'error) Eta.Effect.t;
    acknowledge : 'event -> (unit, 'error) Eta.Effect.t;
    finish_error : 'event -> delivered:bool -> (unit, 'error) Eta.Effect.t;
  }

  let create ~active ~claim ~after_claim ~construct ~run_callback ~acknowledge
      ~finish_error =
    {
      active;
      claim;
      after_claim;
      construct;
      run_callback;
      acknowledge;
      finish_error;
    }

  let run_claimed ops event =
    let open Eta in
    let delivered = ref false in
    (ops.after_claim ()
    |> Effect.bind (fun () -> ops.construct event)
    |> Effect.bind (function
         | None -> Effect.unit
         | Some callback ->
             ops.run_callback event callback
             |> Effect.bind (fun () ->
                    Effect.sync (fun () -> delivered := true))
             |> Effect.bind (fun () -> ops.acknowledge event)))
    |> Effect.on_exit (function
         | Exit.Ok _ -> Effect.unit
         | Exit.Error _ -> ops.finish_error event ~delivered:!delivered)

  let rec run ops = function
    | [] -> Eta.Effect.unit
    | event :: rest ->
        let open Eta in
        ops.active event
        |> Effect.bind (function
             | false -> run ops rest
             | true -> (
                 ops.claim event
                 |> Effect.bind (function
                      | false -> run ops rest
                      | true ->
                          run_claimed ops event
                          |> Effect.bind (fun () -> run ops rest))))
end

module Delivery_event = struct
  type ('callback, 'error) t = {
    mark_pending : unit -> unit;
    active : unit -> (bool, 'error) Eta.Effect.t;
    claim : unit -> (bool, 'error) Eta.Effect.t;
    construct : unit -> ('callback option, 'error) Eta.Effect.t;
    run_callback : 'callback -> (unit, 'error) Eta.Effect.t;
    acknowledge : unit -> (unit, 'error) Eta.Effect.t;
    finish_error : delivered:bool -> (unit, 'error) Eta.Effect.t;
  }

  let create ~mark_pending ~active ~claim ~construct ~run_callback
      ~acknowledge ~finish_error =
    {
      mark_pending;
      active;
      claim;
      construct;
      run_callback;
      acknowledge;
      finish_error;
    }

  let mark_pending event = event.mark_pending ()

  let run ~after_claim events =
    Delivery_runner.run
      (Delivery_runner.create
         ~active:(fun event -> event.active ())
         ~claim:(fun event -> event.claim ())
         ~after_claim
         ~construct:(fun event -> event.construct ())
         ~run_callback:(fun event callback -> event.run_callback callback)
         ~acknowledge:(fun event -> event.acknowledge ())
         ~finish_error:(fun event ~delivered ->
           event.finish_error ~delivered))
      events
end

let plan_event_parts ~equal ~changed ~value delivery =
  let update, delivery =
    match Delivery.base delivery with
    | None -> (Some (Update.Initialized value), None)
    | Some old_value ->
        if changed || Delivery.pending delivery then
          if equal old_value value then
            (None, Some (Delivery.Observer_delivered value))
          else
            ( Some (Update.Changed { old_value; new_value = value }),
              None )
        else (None, None)
  in
  (Value.current value, update, delivery)

module Snapshot = struct
  type ('a, 'after_ack) t = {
    value : 'a Value.t;
    delivery : ('a, 'after_ack) Delivery.t;
  }

  type ('a, 'after_ack) finish =
    | Finish_acknowledged of ('a, 'after_ack) t * 'after_ack list
    | Finish_released of ('a, 'after_ack) t

  type ('a, 'after_ack) event_plan = {
    snapshot : ('a, 'after_ack) t;
    update : 'a Update.t option;
  }

  let create ~value ~delivery = { value; delivery }

  let initial =
    create ~value:Value.uninitialized
      ~delivery:Delivery.Observer_never_delivered

  let value snapshot = snapshot.value
  let delivery snapshot = snapshot.delivery
  let with_value snapshot value = { snapshot with value }
  let with_delivery snapshot delivery = { snapshot with delivery }

  let with_pending_delivery ~token update snapshot =
    with_delivery snapshot (Delivery.pending_state ~token update)

  let acknowledge_delivery ~token ~update ~after_ack snapshot =
    Delivery.acknowledge ~token ~update ~after_ack snapshot.delivery
    |> Option.map (fun (delivery, after_ack) ->
           (with_delivery snapshot delivery, after_ack))

  let claim_delivery ~token snapshot =
    Delivery.claim ~token snapshot.delivery
    |> Option.map (with_delivery snapshot)

  let release_delivery ~token snapshot =
    Delivery.release ~token snapshot.delivery
    |> Option.map (with_delivery snapshot)

  let finish_running_delivery ~token ~update ~delivered ~after_ack snapshot =
    match
      Delivery.finish_running ~token ~update ~delivered ~after_ack
        snapshot.delivery
    with
    | Some (Delivery.Finish_acknowledged (delivery, after_ack)) ->
        Some (Finish_acknowledged (with_delivery snapshot delivery, after_ack))
    | Some (Delivery.Finish_released delivery) ->
        Some (Finish_released (with_delivery snapshot delivery))
    | None -> None

  let running_delivery_token_matches ~token snapshot =
    Delivery.running_token_matches ~token snapshot.delivery

  let plan_event ~equal ~changed ~value snapshot =
    let value, update, delivery =
      plan_event_parts ~equal ~changed ~value snapshot.delivery
    in
    let snapshot = with_value snapshot value in
    let snapshot =
      match delivery with
      | None -> snapshot
      | Some delivery -> with_delivery snapshot delivery
    in
    { snapshot; update }
end

type ('observer, 'live, 'a, 'after_ack) delivery_port = {
  delivery_live : 'observer -> 'live option;
  delivery_snapshot : 'live -> ('a, 'after_ack) Snapshot.t;
  delivery_set_snapshot : 'live -> ('a, 'after_ack) Snapshot.t -> unit;
  delivery_run_after_ack : 'after_ack list -> unit;
}

let acknowledge_delivery port observer token update ~after_ack =
  match port.delivery_live observer with
  | None -> ()
  | Some live -> (
      match
        Snapshot.acknowledge_delivery ~token ~update ~after_ack
          (port.delivery_snapshot live)
      with
      | Some (snapshot, after_ack) ->
          port.delivery_set_snapshot live snapshot;
          port.delivery_run_after_ack after_ack
      | None -> ())

let claim_delivery port observer token =
  match port.delivery_live observer with
  | None -> false
  | Some live -> (
      match
        Snapshot.claim_delivery ~token (port.delivery_snapshot live)
      with
      | Some snapshot ->
          port.delivery_set_snapshot live snapshot;
          true
      | None -> false)

let finish_delivery_after_error port observer token update ~delivered =
  match port.delivery_live observer with
  | None -> ()
  | Some live -> (
      match
        Snapshot.finish_running_delivery ~token ~update ~delivered
          ~after_ack:[] (port.delivery_snapshot live)
      with
      | Some (Snapshot.Finish_acknowledged (snapshot, after_ack)) ->
          port.delivery_set_snapshot live snapshot;
          port.delivery_run_after_ack after_ack
      | Some (Snapshot.Finish_released snapshot) ->
          port.delivery_set_snapshot live snapshot
      | None -> ())

let running_delivery_token_matches port observer token =
  match port.delivery_live observer with
  | None -> false
  | Some live ->
      Snapshot.running_delivery_token_matches ~token
        (port.delivery_snapshot live)

type ('observer, 'a, 'callback, 'error) delivery_event_port = {
  event_active : 'observer -> (bool, 'error) Eta.Effect.t;
  event_construct :
    'observer ->
    Delivery.token ->
    'a Update.t ->
    ('callback option, 'error) Eta.Effect.t;
  event_run_callback :
    'observer ->
    Delivery.token ->
    'callback ->
    (unit, 'error) Eta.Effect.t;
}

type 'error delivery_event_access = {
  event_with_delivery_access :
    'a. (unit -> 'a) -> ('a, 'error) Eta.Effect.t;
}

let make_delivery_event ~access delivery_port event_port ~observer ~token update =
  Delivery_event.create
    ~mark_pending:(fun () ->
      match delivery_port.delivery_live observer with
      | None -> ()
      | Some live ->
          delivery_port.delivery_set_snapshot live
            (Snapshot.with_pending_delivery ~token update
               (delivery_port.delivery_snapshot live)))
    ~active:(fun () -> event_port.event_active observer)
    ~claim:(fun () ->
      access.event_with_delivery_access (fun () ->
          claim_delivery delivery_port observer token))
    ~construct:(fun () ->
      event_port.event_construct observer token update)
    ~run_callback:(fun callback ->
      event_port.event_run_callback observer token callback)
    ~acknowledge:(fun () ->
      access.event_with_delivery_access (fun () ->
          acknowledge_delivery delivery_port observer token update
            ~after_ack:[]))
    ~finish_error:(fun ~delivered ->
      access.event_with_delivery_access (fun () ->
          finish_delivery_after_error delivery_port observer token update
            ~delivered))

module Event = struct
  type ('a, 'after_ack) plan = {
    value : 'a Value.t;
    update : 'a Update.t option;
    delivery : ('a, 'after_ack) Delivery.t option;
  }

  let plan ~equal ~changed ~value delivery =
    let value, update, delivery =
      plan_event_parts ~equal ~changed ~value delivery
    in
    { value; update; delivery }
end
