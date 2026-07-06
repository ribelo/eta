type ('source, 'inner, 'scope) snapshot = {
  source_value : 'source option;
  inner : 'inner option;
  inner_scope : 'scope option;
}

type ('inner, 'dependency) dynamic_dependencies = {
  dependency_source : 'dependency;
  dependency_pack_inner : 'inner -> 'dependency;
}

let dynamic_dependencies ~source ~pack_inner =
  { dependency_source = source; dependency_pack_inner = pack_inner }

type ('capability, 'source, 'inner, 'dependency) dynamic_source_plan = {
  source_equal : 'source -> 'source -> bool;
  source_compute : 'capability -> 'source * bool;
  source_dependencies : ('inner, 'dependency) dynamic_dependencies;
}

let dynamic_source_plan ~equal ~compute_source ~dependencies =
  {
    source_equal = equal;
    source_compute = compute_source;
    source_dependencies = dependencies;
  }

type ('capability, 'inner, 'scope) dynamic_scope_plan = {
  scope_new : 'capability -> 'scope;
  scope_with_current : 'capability -> 'scope -> (unit -> 'inner) -> 'inner;
  scope_on_switch_failure : 'capability -> 'scope -> unit;
}

let dynamic_scope_plan ~new_scope ~with_scope ~on_switch_failure =
  {
    scope_new = new_scope;
    scope_with_current = with_scope;
    scope_on_switch_failure = on_switch_failure;
  }

type ('capability, 'source, 'inner, 'scope, 'value, 'error)
     dynamic_inner_plan = {
  inner_select : 'source -> 'inner;
  scope_validate_inner :
    'capability ->
    'scope ->
    'inner ->
    (unit, ([> `Invalid_scope ] as 'error)) result;
  scope_compute_inner : 'capability -> 'inner -> 'value * bool;
}

let dynamic_inner_plan ~selector ~validate_inner ~compute_inner =
  {
    inner_select = selector;
    scope_validate_inner = validate_inner;
    scope_compute_inner = compute_inner;
  }

type ('capability, 'source, 'inner, 'scope, 'value, 'error)
     dynamic_scope_context = {
  scope_plan : ('capability, 'inner, 'scope) dynamic_scope_plan;
  inner_plan :
    ('capability, 'source, 'inner, 'scope, 'value, 'error)
    dynamic_inner_plan;
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

type ('capability, 'dependency) dynamic_reuse_plan = {
  reuse_dirty : bool;
  reuse_initialized : unit -> bool;
  reuse_dependencies_changed : 'capability -> 'dependency list -> bool;
}

type ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
     dynamic_eval_context = {
  eval_source :
    ('capability, 'source, 'inner, 'dependency) dynamic_source_plan;
  eval_scope :
    ('capability, 'source, 'inner, 'scope, 'value, 'error)
    dynamic_scope_context;
  eval_reuse : ('capability, 'dependency) dynamic_reuse_plan;
}

type 'value dynamic_value_context = {
  value_current : unit -> 'value option;
  value_cached : unit -> 'value;
  value_initialized : unit -> bool;
  value_equal : 'value -> 'value -> bool;
  value_bump_recompute : unit -> unit;
}

type ('source, 'inner, 'scope, 'dependency, 'value)
     dynamic_staging_context = {
  staging_stage_switch :
    source_value:'source -> inner:'inner -> scope:'scope -> unit;
  staging_stage_dependencies : 'dependency list -> unit;
  staging_stage_value : 'value -> unit;
}

type ('source, 'inner, 'scope, 'dependency, 'value) dynamic_apply_context = {
  apply_value : 'value dynamic_value_context;
  apply_staging :
    ('source, 'inner, 'scope, 'dependency, 'value)
    dynamic_staging_context;
}

type ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
     dynamic_context = {
  dynamic_eval :
    ('capability, 'source, 'inner, 'scope, 'dependency, 'value, 'error)
    dynamic_eval_context;
  dynamic_apply :
    ('source, 'inner, 'scope, 'dependency, 'value) dynamic_apply_context;
}

let dynamic_reuse_plan ~dirty ~initialized ~dependencies_changed =
  {
    reuse_dirty = dirty;
    reuse_initialized = initialized;
    reuse_dependencies_changed = dependencies_changed;
  }

let dynamic_value_context ~current_value ~cached_value ~initialized
    ~value_equal ~bump_recompute =
  {
    value_current = current_value;
    value_cached = cached_value;
    value_initialized = initialized;
    value_equal;
    value_bump_recompute = bump_recompute;
  }

let dynamic_staging_context ~stage_switch ~stage_dependencies ~stage_value =
  {
    staging_stage_switch = stage_switch;
    staging_stage_dependencies = stage_dependencies;
    staging_stage_value = stage_value;
  }

let dynamic_context ~source ~scope ~inner ~reuse ~value ~staging =
  {
    dynamic_eval =
      {
        eval_source = source;
        eval_scope = { scope_plan = scope; inner_plan = inner };
        eval_reuse = reuse;
      };
    dynamic_apply = { apply_value = value; apply_staging = staging };
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

let dynamic_dependency_list dynamic_dependencies inner =
  dependencies ~source:dynamic_dependencies.dependency_source
    ~inner:(Option.map dynamic_dependencies.dependency_pack_inner inner)

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

let eval_reuse ~dependencies ~source_changed ~compute_inner ~dirty
    ~initialized ~dependencies_changed =
  let value, inner_changed = compute_inner () in
  if
    dirty || source_changed || inner_changed || dependencies_changed dependencies
    || not initialized
  then Reuse_recompute { reuse_dependencies = dependencies; reuse_value = value }
  else Reuse_cached

let plan_dynamic_unlocked ~capability ~equal snapshot ~dependencies
    ~source_value ~source_changed ~scope ~reuse =
  match eval_plan ~equal snapshot ~source_value with
  | Error _ as error -> error
  | Ok Switch ->
      let dynamic_scope = scope.scope_plan.scope_new capability in
      eval_switch ~capability ~scope:dynamic_scope ~source_value
        ~selector:scope.inner_plan.inner_select
        ~with_scope:scope.scope_plan.scope_with_current
        ~validate_inner:scope.inner_plan.scope_validate_inner
        ~compute_inner:scope.inner_plan.scope_compute_inner
        ~on_failure:scope.scope_plan.scope_on_switch_failure
      |> Result.map (fun eval ->
             Dynamic_switch
               {
                 dynamic_source_value = source_value;
                 dynamic_inner = eval.eval_inner;
                 dynamic_scope;
                 dynamic_switch_dependencies =
                   dynamic_dependency_list dependencies
                     (Some eval.eval_inner);
                 dynamic_switch_value = eval.eval_value;
               })
  | Ok (Reuse inner) -> (
      let dependency_list = dynamic_dependency_list dependencies (Some inner) in
      match
        eval_reuse ~dependencies:dependency_list ~source_changed
          ~compute_inner:(fun () ->
            scope.inner_plan.scope_compute_inner capability inner)
          ~dirty:reuse.reuse_dirty
          ~initialized:(reuse.reuse_initialized ())
          ~dependencies_changed:(fun dependencies ->
            reuse.reuse_dependencies_changed capability dependencies)
      with
      | Reuse_cached -> Ok Dynamic_reuse_cached
      | Reuse_recompute { reuse_dependencies; reuse_value } ->
          Ok
            (Dynamic_reuse_recompute
               {
                 dynamic_reuse_dependencies = reuse_dependencies;
                 dynamic_reuse_value = reuse_value;
               }))

let plan_dynamic eval_context capability snapshot =
  let source = eval_context.eval_source in
  let source_value, source_changed = source.source_compute capability in
  plan_dynamic_unlocked ~capability ~equal:source.source_equal snapshot
    ~source_value ~dependencies:source.source_dependencies
    ~source_changed ~scope:eval_context.eval_scope
    ~reuse:eval_context.eval_reuse

let value_changed context value =
  (not (context.value_initialized ()))
  ||
  match context.value_current () with
  | None -> true
  | Some current -> not (context.value_equal current value)

let computed_value_changed context value =
  context.value_bump_recompute ();
  value_changed context value

let publish_computed_value ~value_context ~staging_context value changed =
  if changed then (
    staging_context.staging_stage_value value;
    (value, true))
  else (value_context.value_cached (), false)

let apply_dynamic_plan context plan =
  let value_context = context.apply_value in
  let staging_context = context.apply_staging in
  match plan with
  | Dynamic_switch
      {
        dynamic_source_value;
        dynamic_inner;
        dynamic_scope;
        dynamic_switch_dependencies;
        dynamic_switch_value;
      } ->
      let changed =
        computed_value_changed value_context dynamic_switch_value
      in
      staging_context.staging_stage_switch
        ~source_value:dynamic_source_value
        ~inner:dynamic_inner ~scope:dynamic_scope;
      staging_context.staging_stage_dependencies dynamic_switch_dependencies;
      publish_computed_value ~value_context ~staging_context
        dynamic_switch_value changed
  | Dynamic_reuse_cached -> (value_context.value_cached (), false)
  | Dynamic_reuse_recompute
      { dynamic_reuse_dependencies; dynamic_reuse_value } ->
      let changed =
        computed_value_changed value_context dynamic_reuse_value
      in
      staging_context.staging_stage_dependencies
        dynamic_reuse_dependencies;
      publish_computed_value ~value_context ~staging_context
        dynamic_reuse_value changed

let run_dynamic context capability snapshot =
  match
    plan_dynamic context.dynamic_eval capability snapshot
  with
  | Error _ as error -> error
  | Ok plan -> Ok (apply_dynamic_plan context.dynamic_apply plan)

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

let pack_staged_switch switch = Packed_staged_switch switch

type ('owner, 'inner, 'scope, 'hook) staged_switch_lifecycle = {
  switch_detach_old_inner : 'owner -> 'inner -> unit;
  switch_invalidate_scope : 'scope -> 'hook list;
  switch_attach_new_inner : 'owner -> 'inner -> unit;
}

let staged_switch_lifecycle ~detach_old_inner ~invalidate_scope
    ~attach_new_inner =
  {
    switch_detach_old_inner = detach_old_inner;
    switch_invalidate_scope = invalidate_scope;
    switch_attach_new_inner = attach_new_inner;
  }

let commit_staged_switch switch lifecycle =
  match (switch.owner, switch.staged) with
  | _, None -> Ok []
  | Some owner, Some staged ->
      commit_switch ~current:switch.current ~staged
        ~detach_old_inner:(lifecycle.switch_detach_old_inner owner)
        ~invalidate_old_scope:lifecycle.switch_invalidate_scope
        ~attach_new_inner:(lifecycle.switch_attach_new_inner owner)
  | None, Some _ -> Error `Invalid_scope

let rollback_staged_switch ~staged lifecycle =
  match staged with
  | None -> Ok []
  | Some staged ->
      rollback_switch ~staged
        ~invalidate_new_scope:lifecycle.switch_invalidate_scope

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
