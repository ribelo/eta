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

module Snapshot = struct
  type ('a, 'after_ack) t = {
    value : 'a Value.t;
    delivery : ('a, 'after_ack) Delivery.t;
  }

  let create ~value ~delivery = { value; delivery }

  let initial =
    create ~value:Value.uninitialized
      ~delivery:Delivery.Observer_never_delivered

  let value snapshot = snapshot.value
  let delivery snapshot = snapshot.delivery
  let with_value snapshot value = { snapshot with value }
  let with_delivery snapshot delivery = { snapshot with delivery }
end

module Event = struct
  type ('a, 'after_ack) plan = {
    value : 'a Value.t;
    update : 'a Update.t option;
    delivery : ('a, 'after_ack) Delivery.t option;
  }

  let plan ~equal ~changed ~value delivery =
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
    { value = Value.current value; update; delivery }
end
