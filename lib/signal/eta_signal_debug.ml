let stats_counter ~name value =
  if value = max_int then Error (`Counter_overflow name) else Ok value

let bool_field name value = name ^ "=" ^ string_of_bool value

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
