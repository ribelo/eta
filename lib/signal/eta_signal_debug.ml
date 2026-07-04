let stats_counter ~name value =
  if value = max_int then Error (`Counter_overflow name) else Ok value

let bool_field name value = name ^ "=" ^ string_of_bool value

let remember_latest ~max_count ~id ~equal_id entry entries =
  let entry_id = id entry in
  let rec take remaining = function
    | [] -> []
    | _ when remaining <= 0 -> []
    | entry :: rest -> entry :: take (remaining - 1) rest
  in
  entry
  :: List.filter
       (fun candidate -> not (equal_id (id candidate) entry_id))
       entries
  |> take max_count

type timer_snapshot = {
  timer_active : bool;
  timer_running_generation : int option;
  timer_has_cancel : bool;
  timer_finished : bool;
  timer_generation : int;
}

let timer_fields ?state_label timer =
  let running =
    match timer.timer_running_generation with
    | None -> "none"
    | Some generation -> string_of_int generation
  in
  Option.fold ~none:[] ~some:(fun label -> [ "timer_state=" ^ label ])
    state_label
  @ [
      bool_field "timer_active" timer.timer_active;
      "timer_running=" ^ running;
      bool_field "timer_cancel" timer.timer_has_cancel;
      bool_field "timer_finished" timer.timer_finished;
      "timer_generation=" ^ string_of_int timer.timer_generation;
    ]

type signal_var_snapshot = {
  signal_var_id_label : string;
  signal_var_queued : bool;
  signal_var_updating : bool;
}

type signal_state_snapshot = {
  signal_valid : bool;
  signal_initialized : bool;
  signal_dirty : bool;
  signal_computing : bool;
  signal_dependency_count : int;
  signal_dependent_count : int;
  signal_var : signal_var_snapshot option;
}

let signal_state_fields state =
  [
    bool_field "valid" state.signal_valid;
    bool_field "initialized" state.signal_initialized;
    bool_field "dirty" state.signal_dirty;
    bool_field "computing" state.signal_computing;
    "dependencies=" ^ string_of_int state.signal_dependency_count;
    "dependents=" ^ string_of_int state.signal_dependent_count;
  ]
  @
  match state.signal_var with
  | None -> []
  | Some var ->
      [
        "var_id=" ^ var.signal_var_id_label;
        bool_field "queued" var.signal_var_queued;
        bool_field "updating" var.signal_var_updating;
      ]

type signal_scope_snapshot =
  | Signal_root_scope
  | Signal_child_scope of {
      signal_scope_id_label : string;
      signal_scope_valid : bool;
      signal_scope_owner_label : string;
      signal_scope_parent_label : string;
    }

let signal_scope_fields = function
  | Signal_root_scope ->
      [
        "scope=root";
        "scope_id=root";
        "scope_owner=root";
        "scope_parent=root";
      ]
  | Signal_child_scope scope ->
      [
        "scope="
        ^ scope.signal_scope_id_label
        ^ ":"
        ^ (if scope.signal_scope_valid then "valid" else "invalid");
        "scope_id=" ^ scope.signal_scope_id_label;
        "scope_owner=" ^ scope.signal_scope_owner_label;
        "scope_parent=" ^ scope.signal_scope_parent_label;
      ]

type signal_label_snapshot = {
  signal_kind_label : string;
  signal_id_label : string;
  signal_tombstone : bool;
  signal_state : signal_state_snapshot option;
  signal_scope : signal_scope_snapshot option;
  signal_timer_fields : string list;
}

let signal_label signal =
  let fields =
    [ "kind=" ^ signal.signal_kind_label; "signal_id=" ^ signal.signal_id_label ]
  in
  let fields =
    if signal.signal_tombstone then fields @ [ "tombstone=true" ] else fields
  in
  let fields =
    match signal.signal_state with
    | None -> fields
    | Some state -> fields @ signal_state_fields state
  in
  let fields =
    match signal.signal_scope with
    | None -> fields
    | Some scope -> fields @ signal_scope_fields scope
  in
  String.concat " " (fields @ signal.signal_timer_fields)

type observer_snapshot = {
  observer_id_label : string;
  observer_state_label : string;
  observer_value_state_label : string;
  observer_delivery_state_label : string;
  observer_missing_observed_signal_id_label : string option;
}

let observer_label observer =
  let fields =
    [
      "observer:" ^ observer.observer_id_label;
      "observer_id=" ^ observer.observer_id_label;
      "state=" ^ observer.observer_state_label;
      "value_state=" ^ observer.observer_value_state_label;
      "delivery_state=" ^ observer.observer_delivery_state_label;
    ]
    @
    match observer.observer_missing_observed_signal_id_label with
    | None -> []
    | Some id -> [ "missing_observed_signal_id=" ^ id ]
  in
  String.concat " " fields

type dot_node = {
  dot_node_id : string;
  dot_node_label : string;
  dot_node_dependency_ids : string list;
}

type dot_observer = {
  dot_observer_id : string;
  dot_observer_label : string;
  dot_observed_signal_id : string option;
}

let render_node formatter node =
  Format.fprintf formatter "  %s [label=%S];@." node.dot_node_id
    node.dot_node_label;
  let emitted_edges = Hashtbl.create 8 in
  List.iter
    (fun dependency_id ->
      if not (Hashtbl.mem emitted_edges dependency_id) then (
        Hashtbl.add emitted_edges dependency_id ();
        Format.fprintf formatter "  %s -> %s;@." dependency_id
          node.dot_node_id))
    node.dot_node_dependency_ids

let render_observer formatter observer =
  Format.fprintf formatter "  %s [shape=box,label=%S];@."
    observer.dot_observer_id observer.dot_observer_label;
  Option.iter
    (fun observed_signal_id ->
      Format.fprintf formatter
        "  %s -> %s [style=dashed,label=\"observes\"];@."
        observed_signal_id observer.dot_observer_id)
    observer.dot_observed_signal_id

let render_dot ~nodes ~observers =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Format.fprintf formatter "digraph eta_signal {@.";
  List.iter (render_node formatter) nodes;
  List.iter (render_observer formatter) observers;
  Format.fprintf formatter "}@.";
  Format.pp_print_flush formatter ();
  Buffer.contents buffer
