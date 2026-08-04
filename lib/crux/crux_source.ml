open Crux_graph_base

  type 'error terminal =
    | Completed
    | Failed of 'error

  type 'item emit =
    'item ->
    (unit, Endpoint.admission_error) Eta.Effect.t

  type ('item, 'error) producer =
    emit:'item emit ->
    ((unit, 'error) Eta.Effect.t, 'error) Eta.Effect.t

  type ('item, 'error, 'action) mapping = {
    mutable target : 'action Endpoint.t;
    mutable on_item : 'item -> 'action;
    mutable on_terminal : 'error terminal -> 'action;
  }

  type ('spec, 'item, 'error, 'action) state = {
    spec : 'spec;
    scope : int;
    mapping : ('item, 'error, 'action) mapping;
    version : int;
  }

  let source_open producer spec mapping ~scope =
    let open Eta.Syntax in
    let emit item =
      Endpoint.send_owned mapping.target ~scope (mapping.on_item item)
    in
    let terminal outcome =
      Endpoint.send_owned mapping.target ~scope
        (mapping.on_terminal outcome)
      |> Eta.Effect.ignore_errors
    in
    let* opened =
      producer spec ~emit
      |> Eta.Effect.to_result
    in
    match opened with
    | Error error ->
        Eta.Effect.pure (Some (terminal (Failed error)))
    | Ok running ->
        let running =
          let* outcome = Eta.Effect.to_result running in
          match outcome with
          | Ok () -> terminal Completed
          | Error error -> terminal (Failed error)
        in
        Eta.Effect.pure (Some running)

  let create ~spec_equal ~spec ~producer ~target ~on_item ~on_terminal =
    let node = next_global "source node" in
    make_description @@ fun transaction scope ->
    let spec_value = spec.eval transaction scope in
    let producer_value = producer.eval transaction scope in
    let target_value = target.eval transaction scope in
    let on_item_value = on_item.eval transaction scope in
    let on_terminal_value = on_terminal.eval transaction scope in
    let key = (scope, node) in
    let existing =
      match transaction_get transaction key with
      | None -> None
      | Some packed -> Some (Obj.obj packed : (_, _, _, _) state)
    in
    let state =
      match existing with
      | Some state when spec_equal state.spec spec_value.value ->
          transaction.commit_hooks <-
            (fun () ->
              state.mapping.target <- target_value.value;
              state.mapping.on_item <- on_item_value.value;
              state.mapping.on_terminal <- on_terminal_value.value)
            :: transaction.commit_hooks;
          state
      | previous ->
          Option.iter
            (fun state ->
              transaction.removed_scopes <-
                state.scope :: transaction.removed_scopes)
            previous;
          let source_scope = fresh_scope transaction ~parent:scope in
          let mapping =
            {
              target = target_value.value;
              on_item = on_item_value.value;
              on_terminal = on_terminal_value.value;
            }
          in
          transaction.works <-
            {
              scope = source_scope;
              origin = Failure.Owned_work;
              trigger = Failure.Source_opening;
              payload =
                Source_open
                  (source_open producer_value.value spec_value.value mapping
                     ~scope:source_scope);
            }
            :: transaction.works;
          {
            spec = spec_value.value;
            scope = source_scope;
            mapping;
            version = fresh_version transaction.root;
          }
    in
    transaction_set transaction key state;
    { value = (); version = state.version }
