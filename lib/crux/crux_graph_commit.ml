open Crux_graph_base

let scope_live root scope =
  match Int_map.find_opt scope root.scopes with
  | Some state -> state.active
  | None -> false

let commit_transaction (transaction : transaction) =
  let root = transaction.root in
  let scopes_with_additions =
    List.fold_left
      (fun scopes (scope : scope_state) -> Int_map.add scope.id scope scopes)
      root.scopes transaction.added_scopes
  in
  let removed =
    List.fold_left
      (fun set scope -> Int_set.add scope set)
      Int_set.empty transaction.removed_scopes
  in
  let is_removed scope =
    Int_set.exists
      (fun ancestor ->
        scope_is_descendant scopes_with_additions ~ancestor scope)
      removed
  in
  Int_map.iter
    (fun _ (scope : scope_state) ->
      if is_removed scope.id then
        transaction.removed_jobs <-
          List.rev_append scope.jobs transaction.removed_jobs)
    scopes_with_additions;
  Int_map.iter
    (fun _ (scope : scope_state) ->
      if is_removed scope.id then (
        scope.active <- false;
        List.iter (fun revoke -> revoke ()) scope.revokers;
        scope.revokers <- []))
    scopes_with_additions;
  Int_map.iter
    (fun _ (endpoint : endpoint_core) ->
      if is_removed endpoint.scope then endpoint.active <- false)
    root.endpoints;
  let store =
    Cell_map.filter
      (fun (scope, _) _ -> not (is_removed scope))
      (Eta_signal.Owner_transaction.read transaction.owner_transaction
         root.store)
  in
  let store =
    Cell_map.fold Cell_map.add transaction.overlay store
  in
  List.iter
    (function
      | Data_update update ->
          update.source.value <- update.value;
          update.source.version <- update.version)
    (List.rev transaction.data_updates);
  List.iter (fun hook -> hook ()) (List.rev transaction.commit_hooks);
  List.iter
    (fun (scope : scope_state) ->
      if not (is_removed scope.id) then scope.active <- true)
    transaction.added_scopes;
  List.iter
    (fun (endpoint : endpoint_core) ->
      if not (is_removed endpoint.scope) then endpoint.active <- true)
    transaction.added_endpoints;
  List.iter
    (fun (scope_id, revoke) ->
      match Int_map.find_opt scope_id scopes_with_additions with
      | Some scope when not (is_removed scope_id) ->
          scope.revokers <- revoke :: scope.revokers
      | Some _ | None -> ())
    (List.rev transaction.added_revokers);
  root.scopes <-
    Int_map.filter
      (fun _ (scope : scope_state) ->
        scope.active || not (is_removed scope.id))
      scopes_with_additions;
  root.endpoints <-
    List.fold_left
      (fun endpoints (endpoint : endpoint_core) ->
        Int_map.add endpoint.id endpoint endpoints)
      (Int_map.filter
         (fun _ (endpoint : endpoint_core) -> endpoint.active)
         root.endpoints)
      transaction.added_endpoints;
  Eta_signal.Owner_transaction.stage transaction.owner_transaction root.store
    store;
  Eta_signal.Owner_transaction.commit transaction.owner_transaction;
  transaction.owner_committed <- true
