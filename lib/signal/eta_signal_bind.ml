type ('source, 'inner, 'scope) snapshot = {
  source_value : 'source option;
  inner : 'inner option;
  inner_scope : 'scope option;
}

type 'inner eval_plan =
  | Switch
  | Reuse of 'inner

type ('inner, 'value) switch_eval = {
  eval_inner : 'inner;
  eval_value : 'value;
}

type ('dependency, 'value) reuse_eval =
  | Reuse_cached
  | Reuse_recompute of {
      reuse_dependencies : 'dependency list;
      reuse_value : 'value;
    }

type ('source, 'inner, 'scope, 'dependency, 'value) dynamic_plan =
  | Dynamic_switch of {
      dynamic_source_value : 'source;
      dynamic_inner : 'inner;
      dynamic_scope : 'scope;
      dynamic_switch_dependencies : 'dependency list;
      dynamic_switch_value : 'value;
    }
  | Dynamic_reuse_cached
  | Dynamic_reuse_recompute of {
      dynamic_reuse_dependencies : 'dependency list;
      dynamic_reuse_value : 'value;
    }

type ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
     dynamic_eval_context = {
  eval_equal : 'source -> 'source -> bool;
  eval_source_dependency : 'dependency;
  eval_pack_inner : 'inner -> 'dependency;
  eval_new_scope : 'capability -> 'scope;
  eval_selector : 'source -> 'inner;
  eval_with_scope : 'capability -> 'scope -> (unit -> 'inner) -> 'inner;
  eval_validate_inner :
    'capability ->
    'scope ->
    'inner ->
    (unit, ([> `Invalid_scope ] as 'error)) result;
  eval_compute_inner : 'capability -> 'inner -> 'value * bool;
  eval_on_switch_failure : 'capability -> 'scope -> unit;
  eval_dirty : bool;
  eval_initialized : bool;
  eval_dependencies_changed : 'capability -> 'dependency list -> bool;
}

let dynamic_eval_context ~equal ~source_dependency ~pack_inner ~new_scope
    ~selector ~with_scope ~validate_inner ~compute_inner ~on_switch_failure
    ~dirty ~initialized ~dependencies_changed =
  {
    eval_equal = equal;
    eval_source_dependency = source_dependency;
    eval_pack_inner = pack_inner;
    eval_new_scope = new_scope;
    eval_selector = selector;
    eval_with_scope = with_scope;
    eval_validate_inner = validate_inner;
    eval_compute_inner = compute_inner;
    eval_on_switch_failure = on_switch_failure;
    eval_dirty = dirty;
    eval_initialized = initialized;
    eval_dependencies_changed = dependencies_changed;
  }

let empty = { source_value = None; inner = None; inner_scope = None }

let switch ~source_value ~inner ~scope =
  {
    source_value = Some source_value;
    inner = Some inner;
    inner_scope = Some scope;
  }

let source_value snapshot = snapshot.source_value
let inner snapshot = snapshot.inner
let inner_scope snapshot = snapshot.inner_scope

let dependencies ~source ~inner =
  match inner with
  | None -> [ source ]
  | Some inner -> [ source; inner ]

let needs_new_inner ~equal snapshot source_value =
  match snapshot.source_value with
  | None -> true
  | Some previous -> not (equal previous source_value)

let eval_plan ~equal snapshot ~source_value =
  if needs_new_inner ~equal snapshot source_value then Ok Switch
  else
    match snapshot.inner with
    | Some inner -> Ok (Reuse inner)
    | None -> Error `Invalid_scope

let eval_switch ~capability ~scope ~source_value ~selector ~with_scope
    ~validate_inner ~compute_inner ~on_failure =
  try
    let inner =
      with_scope capability scope (fun () -> selector source_value)
    in
    match validate_inner capability scope inner with
    | Error _ as error ->
        on_failure capability scope;
        error
    | Ok () ->
        let value, _inner_changed = compute_inner capability inner in
        Ok { eval_inner = inner; eval_value = value }
  with exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    on_failure capability scope;
    Printexc.raise_with_backtrace exn backtrace

let eval_reuse ~source_dependency ~inner_dependency ~source_changed
    ~compute_inner ~dirty ~initialized ~dependencies_changed =
  let value, inner_changed = compute_inner () in
  let dependencies =
    dependencies ~source:source_dependency ~inner:(Some inner_dependency)
  in
  if
    dirty || source_changed || inner_changed || dependencies_changed dependencies
    || not initialized
  then Reuse_recompute { reuse_dependencies = dependencies; reuse_value = value }
  else Reuse_cached

let plan_dynamic_unlocked ~capability ~equal snapshot ~source_dependency
    ~pack_inner ~source_value ~source_changed ~new_scope ~selector
    ~with_scope ~validate_inner ~compute_inner ~on_switch_failure ~dirty
    ~initialized ~dependencies_changed =
  match eval_plan ~equal snapshot ~source_value with
  | Error _ as error -> error
  | Ok Switch ->
      let scope = new_scope capability in
      eval_switch ~capability ~scope ~source_value ~selector ~with_scope
        ~validate_inner ~compute_inner ~on_failure:on_switch_failure
      |> Result.map (fun eval ->
             let inner_dependency = pack_inner eval.eval_inner in
             Dynamic_switch
               {
                 dynamic_source_value = source_value;
                 dynamic_inner = eval.eval_inner;
                 dynamic_scope = scope;
                 dynamic_switch_dependencies =
                   dependencies ~source:source_dependency
                     ~inner:(Some inner_dependency);
                 dynamic_switch_value = eval.eval_value;
               })
  | Ok (Reuse inner) -> (
      let inner_dependency = pack_inner inner in
      match
        eval_reuse ~source_dependency ~inner_dependency ~source_changed
          ~compute_inner:(fun () -> compute_inner capability inner)
          ~dirty ~initialized
          ~dependencies_changed:(fun dependencies ->
            dependencies_changed capability dependencies)
      with
      | Reuse_cached -> Ok Dynamic_reuse_cached
      | Reuse_recompute { reuse_dependencies; reuse_value } ->
          Ok
            (Dynamic_reuse_recompute
               {
                 dynamic_reuse_dependencies = reuse_dependencies;
                 dynamic_reuse_value = reuse_value;
               }))

let plan_dynamic eval_context capability snapshot ~source_value ~source_changed =
  plan_dynamic_unlocked ~capability ~equal:eval_context.eval_equal snapshot
    ~source_value ~source_dependency:eval_context.eval_source_dependency
    ~pack_inner:eval_context.eval_pack_inner
    ~source_changed ~new_scope:eval_context.eval_new_scope
    ~selector:eval_context.eval_selector
    ~with_scope:eval_context.eval_with_scope
    ~validate_inner:eval_context.eval_validate_inner
    ~compute_inner:eval_context.eval_compute_inner
    ~on_switch_failure:eval_context.eval_on_switch_failure
    ~dirty:eval_context.eval_dirty
    ~initialized:eval_context.eval_initialized
    ~dependencies_changed:eval_context.eval_dependencies_changed

let switch_parts snapshot =
  match (snapshot.source_value, snapshot.inner, snapshot.inner_scope) with
  | Some source_value, Some inner, Some scope -> Some (source_value, inner, scope)
  | _ -> None

let stage_switch ~remember ~stage ~source_value ~inner ~scope =
  remember ();
  stage (switch ~source_value ~inner ~scope)

let stage_transaction_switch transaction staged_snapshot ~remember
    ~source_value ~inner ~scope =
  if not (Eta_signal_transaction.staged transaction staged_snapshot) then
    remember ();
  Eta_signal_transaction.stage transaction staged_snapshot
    (switch ~source_value ~inner ~scope)

let commit_switch ~current ~staged ~detach_old_inner ~invalidate_old_scope
    ~attach_new_inner =
  match switch_parts staged with
  | Some (_, new_inner, _) ->
      Option.iter detach_old_inner current.inner;
      let hooks =
        match current.inner_scope with
        | None -> []
        | Some old_scope -> invalidate_old_scope old_scope
      in
      attach_new_inner new_inner;
      Ok hooks
  | None -> Error `Invalid_scope

let rollback_switch ~staged ~invalidate_new_scope =
  match switch_parts staged with
  | Some (_, _, scope) -> Ok (invalidate_new_scope scope)
  | None -> Error `Invalid_scope

let preflight_switch ~current ~staged ~collect_old_scope =
  match switch_parts staged with
  | Some _ ->
      Option.iter collect_old_scope current.inner_scope;
      Ok ()
  | None -> Error `Invalid_scope

type ('source, 'inner, 'scope, 'owner) staged_switch = {
  owner : 'owner option;
  current : ('source, 'inner, 'scope) snapshot;
  staged : ('source, 'inner, 'scope) snapshot option;
}

let staged_switch ~owner ~current ~staged = { owner; current; staged }

type ('scope, 'owner) packed_staged_switch =
  | Packed_staged_switch :
      ('source, 'inner, 'scope, 'owner) staged_switch
      -> ('scope, 'owner) packed_staged_switch

let commit_staged_switch switch ~detach_old_inner ~invalidate_old_scope
    ~attach_new_inner =
  match (switch.owner, switch.staged) with
  | _, None -> Ok []
  | Some owner, Some staged ->
      commit_switch ~current:switch.current ~staged
        ~detach_old_inner:(detach_old_inner owner)
        ~invalidate_old_scope
        ~attach_new_inner:(attach_new_inner owner)
  | None, Some _ -> Error `Invalid_scope

let rollback_staged_switch ~staged ~invalidate_new_scope =
  match staged with
  | None -> Ok []
  | Some staged -> rollback_switch ~staged ~invalidate_new_scope

let preflight_staged_switch switch ~collect_old_scope =
  match (switch.owner, switch.staged) with
  | _, None -> Ok ()
  | Some owner, Some staged ->
      preflight_switch ~current:switch.current ~staged
        ~collect_old_scope:(collect_old_scope owner)
  | None, Some _ -> Error `Invalid_scope

let collect_staged_switch_invalidations ~init ~switches ~staged_switch
    ~collect_old_scope =
  let rec loop acc = function
    | [] -> Ok acc
    | switch :: rest ->
        let acc_ref = ref acc in
        let (Packed_staged_switch staged) = staged_switch switch in
        (match
           preflight_staged_switch staged ~collect_old_scope:(fun owner scope ->
               acc_ref := collect_old_scope !acc_ref ~owner scope)
         with
        | Ok () -> loop !acc_ref rest
        | Error _ as error -> error)
  in
  loop init switches
