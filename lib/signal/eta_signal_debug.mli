(** Pure diagnostics helpers for Eta_signal internals. *)

val stats_counter :
  name:string -> int -> (int, [> `Counter_overflow of string ]) result

val bool_field : string -> bool -> string

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
