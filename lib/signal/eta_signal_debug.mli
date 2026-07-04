(** Pure diagnostics helpers for Eta_signal internals. *)

val stats_counter :
  name:string -> int -> (int, [> `Counter_overflow of string ]) result

val bool_field : string -> bool -> string

type timer_snapshot = {
  timer_active : bool;
  timer_running_generation : int option;
  timer_has_cancel : bool;
  timer_finished : bool;
  timer_generation : int;
}

val timer_fields : ?state_label:string -> timer_snapshot -> string list

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

val signal_state_fields : signal_state_snapshot -> string list

type signal_scope_snapshot =
  | Signal_root_scope
  | Signal_child_scope of {
      signal_scope_id_label : string;
      signal_scope_valid : bool;
      signal_scope_owner_label : string;
      signal_scope_parent_label : string;
    }

val signal_scope_fields : signal_scope_snapshot -> string list

type signal_label_snapshot = {
  signal_kind_label : string;
  signal_id_label : string;
  signal_tombstone : bool;
  signal_state : signal_state_snapshot option;
  signal_scope : signal_scope_snapshot option;
  signal_timer_fields : string list;
}

val signal_label : signal_label_snapshot -> string

type observer_snapshot = {
  observer_id_label : string;
  observer_state_label : string;
  observer_value_state_label : string;
  observer_delivery_state_label : string;
  observer_missing_observed_signal_id_label : string option;
}

val observer_label : observer_snapshot -> string

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

val render_dot : nodes:dot_node list -> observers:dot_observer list -> string
