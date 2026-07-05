type counter =
  | Callback_delivery_count
  | Recompute_count
  | Dynamic_scope_invalidations
  | Nodes_became_necessary
  | Nodes_became_unnecessary

type t = {
  lane : Eta_signal_lane.t;
  owner_domain : Domain.id;
  mutable next_node_id : int;
  mutable next_scope_id : int;
  mutable callback_delivery_count : int;
  mutable recompute_count : int;
  mutable dynamic_scope_invalidations : int;
  mutable nodes_became_necessary : int;
  mutable nodes_became_unnecessary : int;
  mutable necessary_node_ids : (Eta_signal_id.signal, unit) Hashtbl.t;
}

let create () =
  {
    lane = Eta_signal_lane.create ();
    owner_domain = Domain.self ();
    next_node_id = 0;
    next_scope_id = 1;
    callback_delivery_count = 0;
    recompute_count = 0;
    dynamic_scope_invalidations = 0;
    nodes_became_necessary = 0;
    nodes_became_unnecessary = 0;
    necessary_node_ids = Hashtbl.create 16;
  }

let lane t = t.lane
let owner_domain t = t.owner_domain

let checked_succ name value =
  if value = max_int then Error (`Counter_overflow name)
  else Ok (value + 1)

let next_node_index t =
  let id = t.next_node_id in
  match checked_succ "node id" id with
  | Error _ as error -> error
  | Ok next ->
      t.next_node_id <- next;
      Ok id

let next_signal_id t = Result.map Eta_signal_id.signal (next_node_index t)
let next_var_id t = Result.map Eta_signal_id.var (next_node_index t)
let next_observer_id t = Result.map Eta_signal_id.observer (next_node_index t)

let next_scope_id t =
  let id = t.next_scope_id in
  match checked_succ "scope id" id with
  | Error _ as error -> error
  | Ok next ->
      t.next_scope_id <- next;
      Ok (Eta_signal_id.scope id)

let set_next_node_id t next_node_id = t.next_node_id <- next_node_id
let set_next_scope_id t next_scope_id = t.next_scope_id <- next_scope_id

let counter t = function
  | Callback_delivery_count -> t.callback_delivery_count
  | Recompute_count -> t.recompute_count
  | Dynamic_scope_invalidations -> t.dynamic_scope_invalidations
  | Nodes_became_necessary -> t.nodes_became_necessary
  | Nodes_became_unnecessary -> t.nodes_became_unnecessary

let set_counter t counter value =
  match counter with
  | Callback_delivery_count -> t.callback_delivery_count <- value
  | Recompute_count -> t.recompute_count <- value
  | Dynamic_scope_invalidations -> t.dynamic_scope_invalidations <- value
  | Nodes_became_necessary -> t.nodes_became_necessary <- value
  | Nodes_became_unnecessary -> t.nodes_became_unnecessary <- value

let saturating_succ value =
  if value = max_int then max_int else value + 1

let add_int_capped left right =
  if right <= 0 then left
  else if left > max_int - right then max_int
  else left + right

let bump_counter t target =
  set_counter t target (saturating_succ (counter t target))

let update_necessary_ids t next =
  let summary =
    Eta_signal_graph_algorithms.Demand.summarize_diff
      ~previous:t.necessary_node_ids ~next
  in
  t.nodes_became_necessary <-
    add_int_capped t.nodes_became_necessary summary.became_necessary;
  t.nodes_became_unnecessary <-
    add_int_capped t.nodes_became_unnecessary summary.became_unnecessary;
  t.necessary_node_ids <- next
