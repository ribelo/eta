open Crux_graph_base

module Make (M : Map.S) = struct
  module Keyed_map = Eta_signal_map.Keyed_map (M)

  type ('data, 'result) child = {
    scope : int;
    source : data_source;
    description : 'result t;
    output : 'result;
    output_version : int;
  }

  type ('data, 'result) state = {
    entries :
      ('data, ('data, 'result) child) Keyed_map.entry M.t;
    output : 'result M.t;
    version : int;
  }

  let data_description source =
    make_description @@ fun transaction _scope ->
    let value, version = data_value transaction source in
    { value; version }

  let assoc ?(data_equal = ( == )) input_description ~f =
    let node = next_global "assoc node" in
    make_description @@ fun transaction scope ->
    let input = input_description.eval transaction scope in
    let key = (scope, node) in
    let previous =
      match transaction_get transaction key with
      | None -> None
      | Some packed -> Some (Obj.obj packed : (_, _) state)
    in
    let previous_entries =
      match previous with
      | None -> M.empty
      | Some state -> state.entries
    in
    let changed = ref (Option.is_none previous) in
    let entries =
      Keyed_map.reconcile ~previous:previous_entries
        ~current:input.value ~equal:data_equal
        ~create:(fun map_key data ->
          changed := true;
          let child_scope =
            fresh_scope transaction ~parent:scope
          in
          let source =
            {
              id = next_global "assoc data source";
              value = Obj.repr data;
              version = fresh_version transaction.root;
            }
          in
          let description =
            f ~key:map_key ~data:(data_description source)
          in
          let evaluated =
            description.eval transaction child_scope
          in
          {
            scope = child_scope;
            source;
            description;
            output = evaluated.value;
            output_version = evaluated.version;
          })
        ~retain:(fun _map_key ~data_changed
                       ~previous:_ ~current:data child ->
          if data_changed then (
            ignore (stage_data transaction child.source data : int);
            changed := true);
          let evaluated =
            child.description.eval transaction child.scope
          in
          if evaluated.version <> child.output_version then
            changed := true;
          {
            child with
            output = evaluated.value;
            output_version = evaluated.version;
          })
        ~remove:(fun _map_key _data child ->
          changed := true;
          transaction.removed_scopes <-
            child.scope :: transaction.removed_scopes)
    in
    let children = Keyed_map.children entries in
    let output =
      M.map (fun (child : (_, _) child) -> child.output) children
    in
    let version =
      match previous with
      | Some state when not !changed -> state.version
      | Some _ | None -> fresh_version transaction.root
    in
    let state =
      {
        entries;
        output;
        version;
      }
    in
    transaction_set transaction key state;
    { value = state.output; version }
end
