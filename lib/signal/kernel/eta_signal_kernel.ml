module Effect = Eta.Effect
module Spi = Eta.Spi
module Duration = Eta.Duration
module Queue = Eta.Queue
module Runtime_contract = Eta.Runtime_contract
module Bind = Eta_signal_bind
module Cleanup = Eta_signal_cleanup
module Debug = Eta_signal_debug
module Error = Eta_signal_error
module Graph_algorithms = struct
  module type EDGE_NODE = sig
    type id
    type packed
    type t

    val pack : t -> packed
    val unpack : packed -> t
    val id : t -> id
    val equal_id : id -> id -> bool
    val dependencies : t -> packed list
    val set_dependencies : t -> packed list -> unit
    val dependents : t -> packed list
    val set_dependents : t -> packed list -> unit
  end

  module Make_edges (Node : EDGE_NODE) = struct
    let packed_id packed = Node.id (Node.unpack packed)

    let remove_by_id id packed =
      not (Node.equal_id (packed_id packed) id)

    let remove_dependent ~child ~parent =
      Node.set_dependents child
        (List.filter (remove_by_id (Node.id parent)) (Node.dependents child))

    let detach_dependency ~parent ~child =
      remove_dependent ~child ~parent;
      Node.set_dependencies parent
        (List.filter (remove_by_id (Node.id child)) (Node.dependencies parent))

    let has_id id packed = Node.equal_id (packed_id packed) id

    let has_dependency ~parent ~child =
      List.exists (has_id (Node.id child)) (Node.dependencies parent)

    let has_dependent ~child ~parent =
      List.exists (has_id (Node.id parent)) (Node.dependents child)

    let attach_dependency ~parent ~child =
      if not (has_dependent ~child ~parent) then
        Node.set_dependents child (Node.pack parent :: Node.dependents child);
      if not (has_dependency ~parent ~child) then
        Node.set_dependencies parent (Node.pack child :: Node.dependencies parent)

    let attach_packed_dependency ~parent packed =
      attach_dependency ~parent ~child:(Node.unpack packed)
  end

  module type REACHABLE_NODE = sig
    type id
    type packed

    val id : packed -> id
    val valid : packed -> bool
    val children : packed -> packed list
  end

  module Make_reachable (Node : REACHABLE_NODE) = struct
    let fold ~roots ~init ~f =
      let seen = Hashtbl.create 16 in
      let rec visit acc packed =
        let id = Node.id packed in
        if (not (Node.valid packed)) || Hashtbl.mem seen id then acc
        else (
          Hashtbl.add seen id ();
          List.fold_left visit (f acc packed) (Node.children packed))
      in
      List.fold_left visit init roots

    let ids ~roots =
      fold ~roots ~init:(Hashtbl.create 16) ~f:(fun seen packed ->
          Hashtbl.replace seen (Node.id packed) ();
          seen)
  end

  module Demand = struct
    type 'id transition =
      | Became_necessary of 'id
      | Became_unnecessary of 'id

    type 'id t = 'id transition list

    type summary = {
      became_necessary : int;
      became_unnecessary : int;
    }

    type ('id, 'resource) resource = {
      resource_id : 'id;
      resource_value : 'resource;
    }

    type 'resource resource_state = {
      resource_state_value : 'resource;
      resource_state_necessary : bool;
    }

    let diff ~previous ~next =
      let transitions = ref [] in
      Hashtbl.iter
        (fun id () ->
          if not (Hashtbl.mem previous id) then
            transitions := Became_necessary id :: !transitions)
        next;
      Hashtbl.iter
        (fun id () ->
          if not (Hashtbl.mem next id) then
            transitions := Became_unnecessary id :: !transitions)
        previous;
      !transitions

    let summarize transitions =
      List.fold_left
        (fun summary -> function
          | Became_necessary _ ->
              {
                summary with
                became_necessary = summary.became_necessary + 1;
              }
          | Became_unnecessary _ ->
              {
                summary with
                became_unnecessary = summary.became_unnecessary + 1;
              })
        { became_necessary = 0; became_unnecessary = 0 }
        transitions

    let summarize_diff ~previous ~next = diff ~previous ~next |> summarize

    let resource ~id value =
      { resource_id = id; resource_value = value }

    let classify_resources ~necessary resources =
      List.map
        (fun resource ->
          {
            resource_state_value = resource.resource_value;
            resource_state_necessary =
              Hashtbl.mem necessary resource.resource_id;
          })
        resources

    let resource_state_value state = state.resource_state_value

    let resource_state_necessary state = state.resource_state_necessary
  end

  module type VERSION_NODE = sig
    type id
    type packed

    val id : packed -> id
    val equal_id : id -> id -> bool
    val version : packed -> int
  end

  module Make_versions (Node : VERSION_NODE) = struct
    let snapshot nodes =
      List.map (fun node -> (Node.id node, Node.version node)) nodes

    let rec same_snapshot left right =
      match (left, right) with
      | [], [] -> true
      | (left_id, left_version) :: left_rest,
        (right_id, right_version) :: right_rest ->
          Node.equal_id left_id right_id
          && Int.equal left_version right_version
          && same_snapshot left_rest right_rest
      | [], _ :: _ | _ :: _, [] -> false

    let changed ~current nodes =
      not (same_snapshot current (snapshot nodes))
  end

  module Weak_cell = struct
    type t = Obj.t Weak.t

    let create raw =
      let cell = Weak.create 1 in
      (* Store the raw node, not a short-lived existential wrapper. *)
      Weak.set cell 0 (Some (Obj.repr raw));
      cell

    let value ~pack cell =
      match Weak.get cell 0 with
      | None -> None
      | Some raw -> Some (pack (Obj.obj raw))

    let collect ~pack ~keep cells =
      let rec loop kept_cells kept_values = function
        | [] -> (List.rev kept_cells, List.rev kept_values)
        | cell :: rest -> (
            match value ~pack cell with
            | None -> loop kept_cells kept_values rest
            | Some packed ->
                if keep packed then
                  loop (cell :: kept_cells) (packed :: kept_values) rest
                else loop kept_cells kept_values rest)
      in
      loop [] [] cells
  end

  module Snapshot = struct
    type ('id, 'a) t = {
      value : 'a option;
      initialized : bool;
      version : int;
      dependency_versions : ('id * int) list;
    }

    let empty =
      {
        value = None;
        initialized = false;
        version = 0;
        dependency_versions = [];
      }

    let initialized value =
      {
        value = Some value;
        initialized = true;
        version = 0;
        dependency_versions = [];
      }

    let value snapshot = snapshot.value
    let is_initialized snapshot = snapshot.initialized
    let version snapshot = snapshot.version
    let dependency_versions snapshot = snapshot.dependency_versions
    let with_version snapshot version = { snapshot with version }

    let publish ~advance_version ~current snapshot value =
      let version =
        if snapshot.version = current.version then
          advance_version snapshot.version
        else snapshot.version
      in
      { snapshot with value = Some value; initialized = true; version }

    let with_dependency_versions snapshot dependency_versions =
      { snapshot with dependency_versions }

    let preflight_commit_version ~advance_version ~current ~staged =
      if staged.version <> current.version then
        ignore (advance_version current.version : int)
  end

  module type DIRTY_NODE = sig
    type id
    type packed

    val id : packed -> id
    val equal_id : id -> id -> bool
    val dirty : packed -> bool
    val set_dirty : packed -> bool -> unit
  end

  module Make_dirty (Node : DIRTY_NODE) = struct
    let mark node =
      Node.set_dirty node true

    let same_node node (candidate, _) =
      Node.equal_id (Node.id node) (Node.id candidate)

    let mark_recording_previous entries node =
      let entries =
        if List.exists (same_node node) entries then entries
        else (node, Node.dirty node) :: entries
      in
      mark node;
      entries

    let restore entries =
      List.iter (fun (node, dirty) -> Node.set_dirty node dirty) entries
  end

  module type COMPUTE_NODE = sig
    type packed
    type t

    val pack : t -> packed
    val seen_generation : t -> int
    val set_seen_generation : t -> int -> unit
    val changed_seen : t -> bool
    val set_changed_seen : t -> bool -> unit
    val computing : t -> bool
    val set_computing : t -> bool -> unit
    val computed_generation : t -> int
    val set_computed_generation : t -> int -> unit
  end

  module Make_compute (Node : COMPUTE_NODE) = struct
    let remember ~generation computed node =
      if Node.computed_generation node = generation then computed
      else (
        Node.set_computed_generation node generation;
        Node.pack node :: computed)

    let seen ~generation node =
      Node.seen_generation node = generation

    let changed_seen node =
      Node.changed_seen node

    let run ~generation node ~cycle ~compute =
      if Node.computing node then cycle ()
      else (
        Node.set_computing node true;
        match
          Fun.protect
            ~finally:(fun () -> Node.set_computing node false)
            compute
        with
        | value, changed ->
            Node.set_seen_generation node generation;
            Node.set_changed_seen node changed;
            (value, changed))
  end

  module Value_cutoff = struct
    let changed ~equal ~initialized ~current ~next =
      (not initialized)
      ||
      match current with
      | None -> true
      | Some old_value -> not (equal old_value next)
  end

  module Static_eval = struct
    type ('dependency, 'a) child = {
      dependency : 'dependency;
      value : 'a;
      changed : bool;
    }

    type ('dependency, 'a) result = {
      dependencies : 'dependency list;
      children_changed : bool;
      output : unit -> 'a;
    }

    let child ~dependency (value, changed) = { dependency; value; changed }

    let result ~dependencies ~children_changed output =
      { dependencies; children_changed; output }

    let leaf output =
      { dependencies = []; children_changed = false; output = (fun () -> output) }

    let map a f =
      result ~dependencies:[ a.dependency ] ~children_changed:a.changed
        (fun () -> f a.value)

    let map2 a b f =
      result
        ~dependencies:[ a.dependency; b.dependency ]
        ~children_changed:(a.changed || b.changed)
        (fun () -> f a.value b.value)

    let map3 a b c f =
      result
        ~dependencies:[ a.dependency; b.dependency; c.dependency ]
        ~children_changed:(a.changed || b.changed || c.changed)
        (fun () -> f a.value b.value c.value)

    let map4 a b c d f =
      result
        ~dependencies:[ a.dependency; b.dependency; c.dependency; d.dependency ]
        ~children_changed:(a.changed || b.changed || c.changed || d.changed)
        (fun () -> f a.value b.value c.value d.value)

    let map5 a b c d e f =
      result
        ~dependencies:
          [ a.dependency; b.dependency; c.dependency; d.dependency; e.dependency ]
        ~children_changed:
          (a.changed || b.changed || c.changed || d.changed || e.changed)
        (fun () -> f a.value b.value c.value d.value e.value)

    let map6 a b c d e f_child f =
      result
        ~dependencies:
          [
            a.dependency;
            b.dependency;
            c.dependency;
            d.dependency;
            e.dependency;
            f_child.dependency;
          ]
        ~children_changed:
          (a.changed || b.changed || c.changed || d.changed || e.changed
         || f_child.changed)
        (fun () -> f a.value b.value c.value d.value e.value f_child.value)

    let map7 a b c d e f_child g f =
      result
        ~dependencies:
          [
            a.dependency;
            b.dependency;
            c.dependency;
            d.dependency;
            e.dependency;
            f_child.dependency;
            g.dependency;
          ]
        ~children_changed:
          (a.changed || b.changed || c.changed || d.changed || e.changed
         || f_child.changed || g.changed)
        (fun () ->
          f a.value b.value c.value d.value e.value f_child.value g.value)

    let map8 a b c d e f_child g h f =
      result
        ~dependencies:
          [
            a.dependency;
            b.dependency;
            c.dependency;
            d.dependency;
            e.dependency;
            f_child.dependency;
            g.dependency;
            h.dependency;
          ]
        ~children_changed:
          (a.changed || b.changed || c.changed || d.changed || e.changed
         || f_child.changed || g.changed || h.changed)
        (fun () ->
          f a.value b.value c.value d.value e.value f_child.value g.value
            h.value)

    let map9 a b c d e f_child g h i f =
      result
        ~dependencies:
          [
            a.dependency;
            b.dependency;
            c.dependency;
            d.dependency;
            e.dependency;
            f_child.dependency;
            g.dependency;
            h.dependency;
            i.dependency;
          ]
        ~children_changed:
          (a.changed || b.changed || c.changed || d.changed || e.changed
         || f_child.changed || g.changed || h.changed || i.changed)
        (fun () ->
          f a.value b.value c.value d.value e.value f_child.value g.value h.value
            i.value)

    let all children =
      result
        ~dependencies:(List.map (fun child -> child.dependency) children)
        ~children_changed:(List.exists (fun child -> child.changed) children)
        (fun () -> List.map (fun child -> child.value) children)

    let dependencies result = result.dependencies
    let output result = result.output ()
    let children_changed result = result.children_changed

    type ('dependency, 'a) plan =
      | Use_cached
      | Recompute of {
          dependencies : 'dependency list;
          output : 'a;
          stage_dependencies : bool;
        }

    let should_recompute ~dirty ~initialized ~dependencies_changed result =
      dirty || (not initialized) || result.children_changed
      || dependencies_changed result.dependencies

    let plan ?(stage_dependencies = true) ~dirty ~initialized
        ~dependencies_changed result =
      if should_recompute ~dirty ~initialized ~dependencies_changed result then
        Recompute
          {
            dependencies = result.dependencies;
            output = output result;
            stage_dependencies;
          }
      else Use_cached

    let plan_result plan ~use_cached ~recompute =
      match plan with
      | Use_cached -> use_cached ()
      | Recompute { dependencies; output; stage_dependencies } ->
          recompute ~dependencies ~output ~stage_dependencies
  end
end

module Graph = struct
  module State = struct
    type staging = Staging of unit ref

    type ('pending, 'bind, 'node, 'hook, 'timer, 'refresh) t = {
      mutable generation : int;
      mutable pending : 'pending list;
      mutable staged_binds : 'bind list;
      mutable computed_nodes : 'node list;
      mutable pure_disposal_hooks : 'hook list;
      mutable timer_refresh_disposal_hooks : 'hook list;
      mutable timer_refresh_staged_timers : 'timer list;
      mutable pure_snapshot_commit_count : int;
      mutable next_timer_refresh_token : int;
      mutable active_timer_refresh : 'refresh option;
      mutable active_staging : staging option;
    }

    let create () =
      {
        generation = 0;
        pending = [];
        staged_binds = [];
        computed_nodes = [];
        pure_disposal_hooks = [];
        timer_refresh_disposal_hooks = [];
        timer_refresh_staged_timers = [];
        pure_snapshot_commit_count = 0;
        next_timer_refresh_token = 0;
        active_timer_refresh = None;
        active_staging = None;
      }

    let generation t = t.generation
    let set_generation t generation = t.generation <- generation
    let advance_generation t ~advance = t.generation <- advance t.generation

    let staging_matches left right =
      match (left, right) with
      | Staging left, Staging right -> left == right

    let validate_staging t staging =
      match t.active_staging with
      | Some active when staging_matches active staging -> ()
      | Some _ -> invalid_arg "Eta_signal graph staging token is not active"
      | None -> invalid_arg "Eta_signal graph staging is not active"

    let clear_staging_token t staging =
      validate_staging t staging;
      t.active_staging <- None

    let begin_staging t ~timer_refresh =
      (match t.active_staging with
      | None -> ()
      | Some _ -> invalid_arg "Eta_signal graph staging is already active");
      let staging = Staging (ref ()) in
      t.computed_nodes <- [];
      t.staged_binds <- [];
      t.pure_disposal_hooks <- [];
      t.timer_refresh_disposal_hooks <- [];
      t.timer_refresh_staged_timers <- [];
      t.active_timer_refresh <- timer_refresh;
      t.active_staging <- Some staging;
      staging

    let require_staging t =
      match t.active_staging with
      | Some staging -> staging
      | None -> invalid_arg "Eta_signal graph staging is not active"

    let drain_pending t =
      let pending = List.rev t.pending in
      t.pending <- [];
      pending

    let enqueue_pending t pending = t.pending <- pending :: t.pending

    let remember_computed t staging ~generation node ~project ~remember =
      validate_staging t staging;
      t.computed_nodes <-
        remember ~generation t.computed_nodes (project node)

    let computed_nodes t = t.computed_nodes

    let stage_bind t staging bind =
      validate_staging t staging;
      t.staged_binds <- bind :: t.staged_binds

    let staged_binds t = t.staged_binds

    let remember_pure_disposal_hooks t staging hooks =
      validate_staging t staging;
      t.pure_disposal_hooks <- hooks @ t.pure_disposal_hooks

    let remember_timer_refresh_disposal_hooks t staging hooks =
      validate_staging t staging;
      match t.active_timer_refresh with
      | Some _ ->
          t.timer_refresh_disposal_hooks <-
            hooks @ t.timer_refresh_disposal_hooks
      | None -> remember_pure_disposal_hooks t staging hooks

    let active_timer_refresh t = t.active_timer_refresh
    let clear_active_timer_refresh t = t.active_timer_refresh <- None

    let stage_timer_refresh_timer t staging timer =
      validate_staging t staging;
      t.timer_refresh_staged_timers <- timer :: t.timer_refresh_staged_timers

    let next_timer_refresh_token t ~advance =
      let token = t.next_timer_refresh_token in
      t.next_timer_refresh_token <- advance t.next_timer_refresh_token;
      token

    let set_next_timer_refresh_token t token =
      t.next_timer_refresh_token <- token

    let clear_timer_refresh_staging t ~rollback_dirty ~clear_timer =
      Option.iter rollback_dirty t.active_timer_refresh;
      List.iter clear_timer t.timer_refresh_staged_timers;
      t.timer_refresh_staged_timers <- [];
      t.timer_refresh_disposal_hooks <- []

    type ('bind, 'hook, 'timer, 'refresh) reset_context = {
      reset_rollback_bind : 'bind -> 'hook list;
      reset_rollback_transaction : unit -> unit;
      reset_rollback_timer_refresh_dirty : 'refresh -> unit;
      reset_clear_timer_refresh_timer : 'timer -> unit;
    }

    let reset_context ~rollback_bind ~rollback_transaction
        ~rollback_timer_refresh_dirty ~clear_timer_refresh_timer =
      {
        reset_rollback_bind = rollback_bind;
        reset_rollback_transaction = rollback_transaction;
        reset_rollback_timer_refresh_dirty = rollback_timer_refresh_dirty;
        reset_clear_timer_refresh_timer = clear_timer_refresh_timer;
      }

    let reset_staging t staging context =
      validate_staging t staging;
      let rollback_hooks =
        List.concat_map context.reset_rollback_bind t.staged_binds
      in
      let hooks = rollback_hooks @ t.pure_disposal_hooks in
      context.reset_rollback_transaction ();
      t.computed_nodes <- [];
      t.staged_binds <- [];
      t.pure_disposal_hooks <- [];
      clear_timer_refresh_staging t
        ~rollback_dirty:context.reset_rollback_timer_refresh_dirty
        ~clear_timer:context.reset_clear_timer_refresh_timer;
      clear_staging_token t staging;
      hooks

    type ('bind, 'hook) bind_commit_plan = {
      bind_commit : 'bind -> 'hook list;
    }

    let bind_commit_plan ~commit = { bind_commit = commit }

    type ('node, 'prepared) signal_commit_plan = {
      signal_prepare : 'node -> 'prepared;
      signal_commit : 'prepared -> unit;
    }

    let signal_commit_plan ~prepare_signal ~commit_signal =
      { signal_prepare = prepare_signal; signal_commit = commit_signal }

    type 'timer timer_commit_plan = {
      timer_commit : 'timer -> unit;
    }

    let timer_commit_plan ~commit = { timer_commit = commit }

    type snapshot_commit_plan = {
      snapshot_advance : int -> int;
    }

    let snapshot_commit_plan ~advance_snapshot =
      { snapshot_advance = advance_snapshot }

    type ('bind, 'node, 'prepared, 'hook, 'timer) commit_plan = {
      commit_preflight : unit -> unit;
      commit_binds : ('bind, 'hook) bind_commit_plan;
      commit_signals : ('node, 'prepared) signal_commit_plan;
      commit_timers : 'timer timer_commit_plan;
      commit_snapshot : snapshot_commit_plan;
    }

    let commit_plan ~preflight ~binds ~signals ~timers ~snapshot =
      {
        commit_preflight = preflight;
        commit_binds = binds;
        commit_signals = signals;
        commit_timers = timers;
        commit_snapshot = snapshot;
      }

    let prepare_staging t staging context plan =
      validate_staging t staging;
      context.commit_preflight ();
      let signal_commits =
        List.map context.commit_signals.signal_prepare t.computed_nodes
      in
      List.iter
        (fun bind ->
          Eta_signal_commit_plan.add_write plan (fun () ->
              context.commit_binds.bind_commit bind))
        t.staged_binds;
      List.iter
        (fun timer ->
          Eta_signal_commit_plan.add_write plan (fun () ->
              context.commit_timers.timer_commit timer;
              []))
        t.timer_refresh_staged_timers;
      List.iter
        (fun signal ->
          Eta_signal_commit_plan.add_write plan (fun () ->
              context.commit_signals.signal_commit signal;
              []))
        signal_commits;
      Eta_signal_commit_plan.add_write plan (fun () ->
          let hooks =
            t.pure_disposal_hooks @ t.timer_refresh_disposal_hooks
          in
          t.computed_nodes <- [];
          t.staged_binds <- [];
          t.pure_disposal_hooks <- [];
          t.timer_refresh_disposal_hooks <- [];
          t.timer_refresh_staged_timers <- [];
          t.pure_snapshot_commit_count <-
            context.commit_snapshot.snapshot_advance
              t.pure_snapshot_commit_count;
          clear_staging_token t staging;
          hooks);
      plan

    let pure_snapshot_commit_count t = t.pure_snapshot_commit_count

    let set_pure_snapshot_commit_count t count =
      t.pure_snapshot_commit_count <- count
  end

  module Core = struct
    type counter =
      | Callback_delivery_count
      | Recompute_count
      | Dynamic_scope_invalidations
      | Nodes_became_necessary
      | Nodes_became_unnecessary

    type lane_access = Eta_signal_lane.access

    type lane_hooks = {
      note_waiter_enqueued : unit -> unit;
      note_waiter_compaction : unit -> unit;
    }

    let lane_hooks ~note_waiter_enqueued ~note_waiter_compaction =
      { note_waiter_enqueued; note_waiter_compaction }

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
        lane = Eta_signal_lane.create ~single_domain:true ();
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

    let context_error_message =
      "Eta_signal: signal graph APIs must be called on the domain that created "
      ^ "the graph and not from runtime worker callbacks"

    let ensure_context t =
      if
        Domain.self () <> t.owner_domain
        || Eta.Runtime_contract.in_registered_worker_context ()
      then invalid_arg context_error_message

    let lane_hooks_to_lane hooks =
      Eta_signal_lane.hooks
        ~note_waiter_enqueued:hooks.note_waiter_enqueued
        ~note_waiter_compaction:hooks.note_waiter_compaction

    let with_lane_access t ~leaf_name ~depth_local ~hooks ~after_acquired f =
      Eta_signal_lane.with_sync ~leaf_name ~depth_local
        ~ensure_context:(fun () -> ensure_context t)
        ~hooks:(lane_hooks_to_lane hooks) ~after_acquired t.lane f

    let lane_waiting_count t = Eta_signal_lane.waiting_count t.lane
    let lane_cancelled_count t = Eta_signal_lane.cancelled_count t.lane

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

    let next_observer_id t =
      Result.map Eta_signal_id.observer (next_node_index t)

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

    let bump_counter t (_lane : lane_access) target =
      set_counter t target (saturating_succ (counter t target))

    let update_necessary_ids t (_lane : lane_access) next =
      let summary =
        Graph_algorithms.Demand.summarize_diff
          ~previous:t.necessary_node_ids ~next
      in
      t.nodes_became_necessary <-
        add_int_capped t.nodes_became_necessary summary.became_necessary;
      t.nodes_became_unnecessary <-
        add_int_capped t.nodes_became_unnecessary summary.became_unnecessary;
      t.necessary_node_ids <- next
  end

  type
    ( 'pending,
      'bind,
      'node,
      'hook,
      'timer,
      'refresh,
      'observer,
      'weak_node,
      'dead_node,
      'scope_context )
    t =
    {
      core : Core.t;
      atomic_pass :
        ( ( 'pending,
            'bind,
            'node,
            'hook,
            'timer,
            'refresh,
            'observer,
            'weak_node,
            'dead_node,
            'scope_context )
          t,
          Eta_signal_error.graph_error )
        Eta_signal_atomic_pass.t;
      state :
        ('pending, 'bind, 'node, 'hook, 'timer, 'refresh)
        State.t;
      mutable observers : 'observer list;
      mutable all_nodes : 'weak_node list;
      dead_nodes : 'dead_node Eta_signal_tombstone_index.t;
      tombstone_counters : Eta_signal_tombstone_index.counters;
      current_scope : 'scope_context;
    }

  type lane_access = Core.lane_access

  type lane_hooks = {
    note_waiter_enqueued : unit -> unit;
    note_waiter_compaction : unit -> unit;
  }

  let lane_hooks ~note_waiter_enqueued ~note_waiter_compaction =
    { note_waiter_enqueued; note_waiter_compaction }

  type counter =
    | Callback_delivery_count
    | Recompute_count
    | Dynamic_scope_invalidations
    | Nodes_became_necessary
    | Nodes_became_unnecessary

  type staging = State.staging

  type ('id, 'node) node_identity = {
    identity_id : 'node -> 'id;
    identity_equal_id : 'id -> 'id -> bool;
  }

  let node_identity ~id ~equal_id =
    { identity_id = id; identity_equal_id = equal_id }

  type ('id, 'node) edge_ops = {
    edge_identity : ('id, 'node) node_identity;
    edge_dependencies : 'node -> 'node list;
    edge_set_dependencies : 'node -> 'node list -> unit;
    edge_dependents : 'node -> 'node list;
    edge_set_dependents : 'node -> 'node list -> unit;
  }

  type ('id, 'node) dirty_ops = {
    dirty_identity : ('id, 'node) node_identity;
    dirty : 'node -> bool;
    dirty_set : 'node -> bool -> unit;
  }

  type ('node, 'compute_node) compute_ops = {
    compute_node : 'node -> 'compute_node;
    compute_pack : 'compute_node -> 'node;
    compute_seen_generation : 'compute_node -> int;
    compute_set_seen_generation : 'compute_node -> int -> unit;
    compute_changed_seen : 'compute_node -> bool;
    compute_set_changed_seen : 'compute_node -> bool -> unit;
    compute_computing : 'compute_node -> bool;
    compute_set_computing : 'compute_node -> bool -> unit;
    compute_computed_generation : 'compute_node -> int;
    compute_set_computed_generation : 'compute_node -> int -> unit;
  }

  type ('id, 'node) version_ops = {
    version_identity : ('id, 'node) node_identity;
    version : 'node -> int;
  }

  type ('id, 'node) reachable_ops = {
    reachable_id : 'node -> 'id;
    reachable_valid : 'node -> bool;
    reachable_children : 'node -> 'node list;
  }

  type ('scope_context, 'scope) current_runner = {
    run_current : 'a. 'scope_context -> 'scope -> (unit -> 'a) -> 'a;
  }

  type ('scope_context, 'scope) scope_ops = {
    scope_current : 'scope_context -> 'scope option;
    scope_require_valid_current :
      'scope_context -> ('scope, [ `Ambiguous_scope ]) result;
    scope_with_current : 'a. 'scope_context -> 'scope -> (unit -> 'a) -> 'a;
  }

  let scope_ops ~(current : 'scope_context -> 'scope option)
      ~(require_valid_current :
         'scope_context -> ('scope, [ `Ambiguous_scope ]) result)
      ~(with_current : ('scope_context, 'scope) current_runner) =
    {
      scope_current = current;
      scope_require_valid_current = require_valid_current;
      scope_with_current = with_current.run_current;
    }

  let edge_ops ~identity ~dependencies ~set_dependencies ~dependents
      ~set_dependents =
    {
      edge_identity = identity;
      edge_dependencies = dependencies;
      edge_set_dependencies = set_dependencies;
      edge_dependents = dependents;
      edge_set_dependents = set_dependents;
    }

  let dirty_ops ~identity ~dirty ~set_dirty =
    {
      dirty_identity = identity;
      dirty;
      dirty_set = set_dirty;
    }

  let compute_ops ~node ~pack ~seen_generation ~set_seen_generation
      ~changed_seen ~set_changed_seen ~computing ~set_computing
      ~computed_generation ~set_computed_generation =
    {
      compute_node = node;
      compute_pack = pack;
      compute_seen_generation = seen_generation;
      compute_set_seen_generation = set_seen_generation;
      compute_changed_seen = changed_seen;
      compute_set_changed_seen = set_changed_seen;
      compute_computing = computing;
      compute_set_computing = set_computing;
      compute_computed_generation = computed_generation;
      compute_set_computed_generation = set_computed_generation;
    }

  let version_ops ~identity ~version = { version_identity = identity; version }

  let reachable_ops ~id ~valid ~children =
    { reachable_id = id; reachable_valid = valid; reachable_children = children }

  type ('scope, 'dependency, 'node, 'packed_node, 'weak_node) node_lifecycle =
    {
      node_validate_dependency : 'dependency -> unit;
      node_create : id:Eta_signal_id.signal -> scope:'scope option -> 'node;
      node_reserve_dependencies : 'node -> int -> unit;
      node_reserve_dependents : 'dependency -> unit;
      node_attach_dependency : parent:'node -> child:'dependency -> unit;
      node_add_to_scope : 'scope -> 'node -> unit;
      node_pack : 'node -> 'packed_node;
      node_create_weak : 'packed_node -> 'weak_node;
    }

  type ('node, 'scope, 'hook, 'dead_node) node_invalidation = {
    invalidation_valid : 'node -> bool;
    invalidation_set_invalid : 'node -> unit;
    invalidation_timer_hooks : 'node -> 'hook list;
    invalidation_tombstone : 'node -> 'dead_node;
    invalidation_observer_hooks : 'node -> 'hook list;
    invalidation_detach_edges : 'node -> 'node list;
    invalidation_kind_hooks :
      invalidate_scope:('scope -> 'hook list) ->
      'node ->
      'hook list;
  }

  let node_lifecycle ~validate_dependency ~create ~reserve_dependencies
      ~reserve_dependents ~attach_dependency ~add_to_scope ~pack ~create_weak =
    {
      node_validate_dependency = validate_dependency;
      node_create = create;
      node_reserve_dependencies = reserve_dependencies;
      node_reserve_dependents = reserve_dependents;
      node_attach_dependency = attach_dependency;
      node_add_to_scope = add_to_scope;
      node_pack = pack;
      node_create_weak = create_weak;
    }

  let node_invalidation ~valid ~set_invalid ~timer_hooks ~tombstone
      ~observer_hooks ~detach_edges ~kind_hooks =
    {
      invalidation_valid = valid;
      invalidation_set_invalid = set_invalid;
      invalidation_timer_hooks = timer_hooks;
      invalidation_tombstone = tombstone;
      invalidation_observer_hooks = observer_hooks;
      invalidation_detach_edges = detach_edges;
      invalidation_kind_hooks = kind_hooks;
    }

  let core_counter = function
    | Callback_delivery_count -> Core.Callback_delivery_count
    | Recompute_count -> Core.Recompute_count
    | Dynamic_scope_invalidations -> Core.Dynamic_scope_invalidations
    | Nodes_became_necessary -> Core.Nodes_became_necessary
    | Nodes_became_unnecessary -> Core.Nodes_became_unnecessary

  let create ~create_scope_context () =
    {
      core = Core.create ();
      atomic_pass = Eta_signal_atomic_pass.create ();
      state = State.create ();
      observers = [];
      all_nodes = [];
      dead_nodes = Eta_signal_tombstone_index.create ();
      tombstone_counters = Eta_signal_tombstone_index.create_counters ();
      current_scope = create_scope_context ();
    }

  let context_error_message = Core.context_error_message
  let ensure_context t = Core.ensure_context t.core

  let lane_hooks_to_core hooks =
    Core.lane_hooks
      ~note_waiter_enqueued:hooks.note_waiter_enqueued
      ~note_waiter_compaction:hooks.note_waiter_compaction

  let with_lane_access t ~leaf_name ~depth_local ~hooks ~after_acquired f =
    Core.with_lane_access t.core ~leaf_name ~depth_local
      ~hooks:(lane_hooks_to_core hooks) ~after_acquired f

  let lane_waiting_count t _lane = Core.lane_waiting_count t.core

  let lane_cancelled_count t _lane =
    Core.lane_cancelled_count t.core

  let next_signal_id t = Core.next_signal_id t.core
  let next_var_id t = Core.next_var_id t.core
  let next_observer_id t = Core.next_observer_id t.core
  let next_scope_id t = Core.next_scope_id t.core
  let set_next_node_id t _lane next = Core.set_next_node_id t.core next

  let counter t _lane target =
    Core.counter t.core (core_counter target)

  let set_counter t _lane target value =
    Core.set_counter t.core (core_counter target) value

  let bump_counter t lane target =
    Core.bump_counter t.core lane (core_counter target)

  let identity_id identity node = identity.identity_id node
  let identity_equal identity left right = identity.identity_equal_id left right

  let edge_id ops node = identity_id ops.edge_identity node
  let edge_equal_id ops left right = identity_equal ops.edge_identity left right
  let dirty_id ops node = identity_id ops.dirty_identity node
  let dirty_equal_id ops left right =
    identity_equal ops.dirty_identity left right

  let version_id ops node = identity_id ops.version_identity node
  let version_equal_id ops left right =
    identity_equal ops.version_identity left right

  let remove_by_id ops id node = not (edge_equal_id ops (edge_id ops node) id)

  let has_id ops id node =
    edge_equal_id ops (edge_id ops node) id

  let remove_dependent _t ops ~child ~parent =
    ops.edge_set_dependents child
      (List.filter
         (remove_by_id ops (edge_id ops parent))
         (ops.edge_dependents child))

  let detach_dependency t _lane ops ~parent ~child =
    remove_dependent t ops ~child ~parent;
    ops.edge_set_dependencies parent
      (List.filter
         (remove_by_id ops (edge_id ops child))
         (ops.edge_dependencies parent))

  let has_dependency _t ops ~parent ~child =
    List.exists
      (has_id ops (edge_id ops child))
      (ops.edge_dependencies parent)

  let has_dependent _t ops ~child ~parent =
    List.exists
      (has_id ops (edge_id ops parent))
      (ops.edge_dependents child)

  let attach_dependency t _lane ops ~parent ~child =
    if not (has_dependent t ops ~child ~parent) then
      ops.edge_set_dependents child (parent :: ops.edge_dependents child);
    if not (has_dependency t ops ~parent ~child) then
      ops.edge_set_dependencies parent (child :: ops.edge_dependencies parent)

  let detach_node_edges t _lane ops node =
    let dependencies = ops.edge_dependencies node in
    let dependents = ops.edge_dependents node in
    List.iter
      (fun dependency -> remove_dependent t ops ~child:dependency ~parent:node)
      dependencies;
    ops.edge_set_dependencies node [];
    ops.edge_set_dependents node [];
    (dependencies, dependents)

  let mark_dirty _t _lane ops node = ops.dirty_set node true

  let same_dirty_node ops node (candidate, _) =
    dirty_equal_id ops (dirty_id ops node) (dirty_id ops candidate)

  let mark_dirty_recording_previous t lane ops entries node =
    let entries =
      if List.exists (same_dirty_node ops node) entries then entries
      else (node, ops.dirty node) :: entries
    in
    mark_dirty t lane ops node;
    entries

  let restore_dirty _t _lane ops entries =
    List.iter (fun (node, dirty) -> ops.dirty_set node dirty) entries

  let generation t _lane = State.generation t.state
  let atomic_pass_counters t = Eta_signal_atomic_pass.counters t.atomic_pass

  let atomic_pass_fault_injector t =
    Eta_signal_atomic_pass.fault_injector t.atomic_pass

  let stabilization_idle t =
    Eta_signal_atomic_pass.phase t.atomic_pass = Eta_signal_atomic_pass.Idle

  let set_generation t _lane generation =
    State.set_generation t.state generation

  let advance_generation t =
    let exception Overflow in
    match
      State.advance_generation t.state ~advance:(fun generation ->
          if generation = max_int then raise Overflow else generation + 1)
    with
    | () -> Ok ()
    | exception Overflow -> Error (`Counter_overflow "stabilization generation")

  let begin_staging t ~timer_refresh =
    State.begin_staging t.state ~timer_refresh

  let drain_pending t = State.drain_pending t.state
  let enqueue_pending t _lane pending =
    State.enqueue_pending t.state pending

  let require_active_staging t = State.require_staging t.state

  let remember_compute ops ~generation computed node =
    if ops.compute_computed_generation node = generation then computed
    else (
      ops.compute_set_computed_generation node generation;
      ops.compute_pack node :: computed)

  let remember_computed t lane staging ops node =
    State.remember_computed t.state staging
      ~generation:(generation t lane) node ~project:ops.compute_node
      ~remember:(remember_compute ops)

  let iter_computed t _lane staging ~f =
    if not (State.require_staging t.state == staging) then
      invalid_arg "Eta_signal graph staging token is not active";
    List.iter f (State.computed_nodes t.state)

  let compute_seen t lane ops node =
    Int.equal (ops.compute_seen_generation node) (generation t lane)

  let compute_changed_seen _t ops node = ops.compute_changed_seen node

  let compute_run t lane ops node ~cycle ~compute =
    let generation = generation t lane in
    if ops.compute_computing node then cycle ()
    else (
      ops.compute_set_computing node true;
      match
        Fun.protect
          ~finally:(fun () -> ops.compute_set_computing node false)
          compute
      with
      | value, changed ->
          ops.compute_set_seen_generation node generation;
          ops.compute_set_changed_seen node changed;
          (value, changed))

  let compute_cached t lane ops node ~current ~cycle ~compute =
    let compute_node = ops.compute_node node in
    if compute_seen t lane ops compute_node then
      (current compute_node, compute_changed_seen t ops compute_node)
    else
      compute_run t lane ops compute_node
        ~cycle:(fun () -> cycle compute_node)
        ~compute:(fun () -> compute compute_node)

  let version_snapshot _t _lane ops nodes =
    List.map (fun node -> (version_id ops node, ops.version node)) nodes

  let rec same_version_snapshot ops left right =
    match (left, right) with
    | [], [] -> true
    | (left_id, left_version) :: left_rest,
      (right_id, right_version) :: right_rest ->
        version_equal_id ops left_id right_id
        && Int.equal left_version right_version
        && same_version_snapshot ops left_rest right_rest
    | [], _ :: _ | _ :: _, [] -> false

  let versions_changed t lane ops ~current nodes =
    not
      (same_version_snapshot ops current (version_snapshot t lane ops nodes))

  let fold_reachable _t _lane ops ~roots ~init ~f =
    let seen = Hashtbl.create 16 in
    let rec visit acc node =
      let id = ops.reachable_id node in
      if (not (ops.reachable_valid node)) || Hashtbl.mem seen id then acc
      else (
        Hashtbl.add seen id ();
        List.fold_left visit (f acc node) (ops.reachable_children node))
    in
    List.fold_left visit init roots

  type ('node, 'bind_node) bind_node_selection = {
    reachable_bind_node : 'node -> 'bind_node option;
  }

  let bind_node_selection ~bind = { reachable_bind_node = bind }

  let collect_reachable_bind_nodes t lane ops ~roots selection =
    fold_reachable t lane ops ~roots ~init:[] ~f:(fun selected node ->
        match selection.reachable_bind_node node with
        | None -> selected
        | Some value -> value :: selected)

  let collect_reachable_ids t lane ops ~roots =
    fold_reachable t lane ops ~roots ~init:(Hashtbl.create 16)
      ~f:(fun seen node ->
        Hashtbl.replace seen (ops.reachable_id node) ();
        seen)

  let remember_staged_bind t _lane staging bind =
    State.stage_bind t.state staging bind

  let iter_staged_binds t _lane staging ~f =
    State.validate_staging t.state staging;
    List.iter f (State.staged_binds t.state)

  let stage_bind_switch t lane staging bind snapshot ~source_value ~inner ~scope =
    Eta_signal_bind.stage_transaction_switch
      (Eta_signal_atomic_pass.active_transaction t.atomic_pass)
      snapshot
      ~remember:(fun () -> remember_staged_bind t lane staging bind)
      ~source_value ~inner ~scope

  let graph_error_of_bind_switch_error = function
    | `Invalid_scope -> (`Invalid_scope : Eta_signal_error.graph_error)

  let map_bind_switch_result = function
    | Ok _ as ok -> ok
    | Error err -> Error (graph_error_of_bind_switch_error err)

  let commit_staged_bind_switch switch lifecycle =
    Eta_signal_bind.commit_staged_switch switch lifecycle
    |> map_bind_switch_result

  let rollback_staged_bind_switch ~staged lifecycle =
    Eta_signal_bind.rollback_staged_switch ~staged lifecycle
    |> map_bind_switch_result

  type ('bind, 'scope, 'owner, 'acc) staged_bind_invalidation_plan = {
    staged_bind_invalidation_init : 'acc;
    staged_bind_invalidation_switch :
      'bind -> ('scope, 'owner) Eta_signal_bind.packed_staged_switch;
    staged_bind_invalidation_collect_old_scope :
      'acc -> owner:'owner -> 'scope -> 'acc;
  }

  let staged_bind_invalidation_plan ~init ~staged_switch ~collect_old_scope =
    {
      staged_bind_invalidation_init = init;
      staged_bind_invalidation_switch = staged_switch;
      staged_bind_invalidation_collect_old_scope = collect_old_scope;
    }

  let collect_staged_bind_switch_invalidations t _lane _staging plan =
    Eta_signal_bind.collect_staged_switch_invalidations
      ~init:plan.staged_bind_invalidation_init
      ~switches:(State.staged_binds t.state)
      ~staged_switch:plan.staged_bind_invalidation_switch
      ~collect_old_scope:plan.staged_bind_invalidation_collect_old_scope
    |> map_bind_switch_result

  let remember_pure_disposal_hooks t _lane staging hooks =
    State.remember_pure_disposal_hooks t.state staging hooks

  let remember_timer_refresh_disposal_hooks t _lane staging hooks =
    State.remember_timer_refresh_disposal_hooks t.state staging
      hooks

  let saturating_succ value =
    if value = max_int then max_int else value + 1

  type ('bind, 'hook, 'timer, 'refresh) staging_reset_context = {
    staging_reset_rollback_extensions : staging -> 'hook list;
    staging_reset_rollback_bind :
      staging -> 'bind -> 'hook staged_bind_rollback;
    staging_reset_rollback_timer_refresh_dirty :
      staging -> 'refresh -> staged_timer_refresh_dirty_rollback;
    staging_reset_clear_timer_refresh_timer :
      staging -> 'timer -> staged_timer_reset;
  }

  and 'hook staged_bind_rollback =
    | Staged_bind_rollback : {
        staged_bind_rollback_snapshot :
          ('source, 'inner, 'scope) Eta_signal_bind.snapshot option;
        staged_bind_rollback_lifecycle :
          ('owner, 'inner, 'scope, 'hook)
          Eta_signal_bind.staged_switch_lifecycle;
      }
        -> 'hook staged_bind_rollback

  and staged_timer_reset = Staged_timer_reset of { timer_reset : unit -> unit }

  and staged_timer_refresh_dirty_rollback =
    | Staged_timer_refresh_dirty_rollback of {
        timer_refresh_dirty_rollback : unit -> unit;
      }

  let staged_bind_rollback ~staged ~lifecycle =
    Staged_bind_rollback
      {
        staged_bind_rollback_snapshot = staged;
        staged_bind_rollback_lifecycle = lifecycle;
      }

  let staged_timer_reset ~reset = Staged_timer_reset { timer_reset = reset }

  let staged_timer_refresh_dirty_rollback ~rollback =
    Staged_timer_refresh_dirty_rollback
      { timer_refresh_dirty_rollback = rollback }

  let staging_reset_context ~rollback_extensions ~rollback_bind ~rollback_timer_refresh_dirty
      ~clear_timer_refresh_timer =
    {
      staging_reset_rollback_extensions = rollback_extensions;
      staging_reset_rollback_bind = rollback_bind;
      staging_reset_rollback_timer_refresh_dirty = rollback_timer_refresh_dirty;
      staging_reset_clear_timer_refresh_timer = clear_timer_refresh_timer;
    }

  let rollback_staging_bind staging bind context =
    match context.staging_reset_rollback_bind staging bind with
    | Staged_bind_rollback
        {
          staged_bind_rollback_snapshot;
          staged_bind_rollback_lifecycle;
        } ->
        rollback_staged_bind_switch ~staged:staged_bind_rollback_snapshot
          staged_bind_rollback_lifecycle

  let reset_staging_timer staging timer context =
    match context.staging_reset_clear_timer_refresh_timer staging timer with
    | Staged_timer_reset { timer_reset } -> timer_reset ()

  let rollback_staging_timer_refresh_dirty staging refresh context =
    match
      context.staging_reset_rollback_timer_refresh_dirty staging refresh
    with
    | Staged_timer_refresh_dirty_rollback
        { timer_refresh_dirty_rollback } ->
        timer_refresh_dirty_rollback ()

  let reset_staging t _lane staging context =
    let exception Rollback_error of Eta_signal_error.graph_error in
    let state_context =
      State.reset_context
        ~rollback_bind:(fun bind ->
          match rollback_staging_bind staging bind context with
          | Ok hooks -> hooks
          | Error err -> raise (Rollback_error err))
        ~rollback_transaction:(fun () ->
          Eta_signal_atomic_pass.rollback_transaction t.atomic_pass)
        ~rollback_timer_refresh_dirty:(fun refresh ->
          rollback_staging_timer_refresh_dirty staging refresh context)
        ~clear_timer_refresh_timer:(fun timer ->
          reset_staging_timer staging timer context)
    in
    let extension_hooks =
      context.staging_reset_rollback_extensions staging
    in
    let state_hooks = State.reset_staging t.state staging state_context in
    extension_hooks @ state_hooks

  type 'hook staged_bind_commit =
    | Staged_bind_commit : {
        staged_bind_switch :
          ('source, 'inner, 'scope, 'owner)
          Eta_signal_bind.staged_switch;
        staged_bind_lifecycle :
          ('owner, 'inner, 'scope, 'hook)
          Eta_signal_bind.staged_switch_lifecycle;
      }
        -> 'hook staged_bind_commit

  let staged_bind_commit ~switch ~lifecycle =
    Staged_bind_commit
      { staged_bind_switch = switch; staged_bind_lifecycle = lifecycle }

  type ('bind, 'hook) staging_bind_commit_plan = {
    staging_bind_commit : staging -> 'bind -> 'hook staged_bind_commit;
  }

  let staging_bind_commit_plan ~commit = { staging_bind_commit = commit }

  let commit_staging_bind staging bind context =
    match context.staging_bind_commit staging bind with
    | Staged_bind_commit { staged_bind_switch; staged_bind_lifecycle } ->
        commit_staged_bind_switch staged_bind_switch staged_bind_lifecycle

  type staged_signal_commit =
    | Staged_signal_commit : {
        signal_valid : bool;
        signal_cell : 'snapshot Eta_signal_transaction.staged;
        signal_commit : unit -> unit;
      }
        -> staged_signal_commit

  let staged_signal_commit ~valid ~cell ~commit =
    Staged_signal_commit
      { signal_valid = valid; signal_cell = cell; signal_commit = commit }

  type 'node staging_signal_commit_plan = {
    staging_signal_commit : staging -> 'node -> staged_signal_commit;
  }

  let staging_signal_commit_plan ~commit = { staging_signal_commit = commit }

  let signal_staged_in_active_transaction t cell =
    if Eta_signal_atomic_pass.is_planning t.atomic_pass then
      Eta_signal_transaction.staged
        (Eta_signal_atomic_pass.active_transaction t.atomic_pass)
        cell
    else false

  let prepare_staging_signal t _staging = function
    | Staged_signal_commit { signal_valid; signal_cell; _ } as commit ->
        if
          (not signal_valid)
          && signal_staged_in_active_transaction t signal_cell
        then
          Eta_signal_transaction.discard
            (Eta_signal_atomic_pass.active_transaction t.atomic_pass)
            signal_cell;
        commit

  let commit_staging_signal = function
    | Staged_signal_commit { signal_valid; signal_commit; _ } ->
        if signal_valid then signal_commit ()

  type staged_timer_commit = Staged_timer_commit of { timer_commit : unit -> unit }

  let staged_timer_commit ~commit = Staged_timer_commit { timer_commit = commit }

  type 'timer staging_timer_commit_plan = {
    staging_timer_commit : staging -> 'timer -> staged_timer_commit;
  }

  let staging_timer_commit_plan ~commit = { staging_timer_commit = commit }

  let commit_staging_timer staging timer context =
    match context.staging_timer_commit staging timer with
    | Staged_timer_commit { timer_commit } -> timer_commit ()

  type staged_preflight = Staged_preflight of { preflight : unit -> unit }

  let staged_preflight ~preflight = Staged_preflight { preflight }

  let run_staging_preflight staging preflight =
    match preflight staging with
    | Staged_preflight { preflight } -> preflight ()

  type ('bind, 'node, 'hook, 'timer) staging_commit_plan = {
    staging_commit_preflight : staging -> staged_preflight;
    staging_commit_binds : ('bind, 'hook) staging_bind_commit_plan;
    staging_commit_signals : 'node staging_signal_commit_plan;
    staging_commit_timers : 'timer staging_timer_commit_plan;
    staging_commit_finalize : unit -> 'hook list;
  }

  let staging_commit_plan ~preflight ~binds ~signals ~timers ~finalize =
    {
      staging_commit_preflight = preflight;
      staging_commit_binds = binds;
      staging_commit_signals = signals;
      staging_commit_timers = timers;
      staging_commit_finalize = finalize;
    }

  let prepare_staging t _lane staging context =
    let exception Commit_error of Eta_signal_error.graph_error in
    let state_plan =
      State.commit_plan
        ~preflight:(fun () ->
          run_staging_preflight staging context.staging_commit_preflight)
        ~binds:
          (State.bind_commit_plan
             ~commit:(fun bind ->
               match
                 commit_staging_bind staging bind context.staging_commit_binds
               with
               | Ok hooks -> hooks
               | Error err -> raise (Commit_error err)))
        ~signals:
          (State.signal_commit_plan
             ~prepare_signal:(fun node ->
               context.staging_commit_signals.staging_signal_commit
                 staging node
               |> prepare_staging_signal t staging)
             ~commit_signal:commit_staging_signal)
        ~timers:
          (State.timer_commit_plan
             ~commit:(fun timer ->
               commit_staging_timer staging timer
                 context.staging_commit_timers))
        ~snapshot:
          (State.snapshot_commit_plan
             ~advance_snapshot:saturating_succ)
    in
    try
      let plan = Eta_signal_atomic_pass.new_commit_plan t.atomic_pass in
      let plan = State.prepare_staging t.state staging state_plan plan in
      Eta_signal_commit_plan.add_write plan (fun () ->
          context.staging_commit_finalize ());
      Ok plan
    with Commit_error err -> Error err

  let pure_snapshot_commit_count t _lane =
    State.pure_snapshot_commit_count t.state

  let set_pure_snapshot_commit_count t _lane count =
    State.set_pure_snapshot_commit_count t.state count

  let active_transaction t =
    Eta_signal_atomic_pass.active_transaction t.atomic_pass

  let read_effective t cell =
    if Eta_signal_atomic_pass.is_planning t.atomic_pass then
      Eta_signal_transaction.read (active_transaction t) cell
    else Eta_signal_transaction.current cell

  let stage_cell t _lane _staging cell value =
    Eta_signal_transaction.stage (active_transaction t) cell value

  let publish_or_stage t writer cell value =
    if Eta_signal_atomic_pass.accepts_staging t.atomic_pass then
      Eta_signal_transaction.stage (active_transaction t) cell value
    else Eta_signal_transaction.publish_current writer cell value

  let discard_cell t _lane _staging cell =
    Eta_signal_transaction.discard (active_transaction t) cell

  let update_cell t _lane _staging cell f =
    let transaction = active_transaction t in
    let value = Eta_signal_transaction.read transaction cell in
    Eta_signal_transaction.stage transaction cell (f value)

  let staged_in_active_transaction t _lane _staging cell =
    Eta_signal_atomic_pass.is_planning t.atomic_pass
    && Eta_signal_transaction.staged (active_transaction t) cell

  let staged_value t _lane _staging cell =
    if Eta_signal_atomic_pass.is_planning t.atomic_pass then
      let transaction = active_transaction t in
      if Eta_signal_transaction.staged transaction cell then
        Some (Eta_signal_transaction.read transaction cell)
      else None
    else None

  let next_timer_refresh_token t _lane =
    let exception Overflow in
    match
      State.next_timer_refresh_token t.state
        ~advance:(fun token ->
          if token = max_int then raise Overflow else token + 1)
    with
    | token -> Ok token
    | exception Overflow -> Error (`Counter_overflow "timer refresh token")

  let set_next_timer_refresh_token t _lane token =
    State.set_next_timer_refresh_token t.state token

  let mark_timer_refresh_dirty t _lane _staging ~mark ~record =
    match State.active_timer_refresh t.state with
    | None -> mark ()
    | Some refresh -> record refresh

  let timer_has_staged_refresh t timer ~refresh_token ~staged_token =
    match State.active_timer_refresh t.state with
    | Some refresh -> staged_token timer = refresh_token refresh
    | None -> false

  let remember_timer_refresh_timer t _lane staging timer ~refresh_token
      ~staged_token ~set_staged_token ~stage_refresh_token =
    match State.active_timer_refresh t.state with
    | None -> ()
    | Some refresh ->
        let token = refresh_token refresh in
        if staged_token timer <> token then (
          set_staged_token timer token;
          stage_refresh_token timer token;
          State.stage_timer_refresh_timer t.state staging timer)

  let with_timer_refresh_timer t _lane timer ~none ~some =
    match (State.active_timer_refresh t.state, timer) with
    | Some refresh, Some timer -> some refresh timer
    | None, _ | Some _, None -> none ()

  let allocation_scope t ops =
    match Eta_signal_atomic_pass.phase t.atomic_pass with
    | Idle -> Ok (ops.scope_current t.current_scope)
    | Planning -> (
        match ops.scope_require_valid_current t.current_scope with
        | Ok scope -> Ok (Some scope)
        | Error `Ambiguous_scope -> Error `Ambiguous_scope)
    | Delivering -> Error `Ambiguous_scope

  let with_current_scope t ops scope f =
    ops.scope_with_current t.current_scope scope f

  let ensure_not_pure t =
    if Eta_signal_atomic_pass.is_planning t.atomic_pass then
      Error `Ambiguous_scope
    else Ok ()

  let add_observer t _lane observer = t.observers <- observer :: t.observers

  type 'observer observer_identity = {
    observer_same : 'observer -> 'observer -> bool;
  }

  let observer_identity ~same = { observer_same = same }

  let remove_observer t _lane identity observer =
    t.observers <-
      List.filter
        (fun candidate -> not (identity.observer_same candidate observer))
        t.observers

  type ('observer, 'hook) observer_cleanup = {
    observer_cleanup_selected : 'observer -> bool;
    observer_cleanup_hooks : 'observer -> 'hook list;
  }

  let observer_cleanup ~selected ~cleanup =
    {
      observer_cleanup_selected = selected;
      observer_cleanup_hooks = cleanup;
    }

  let collect_observer_cleanup_hooks t _lane cleanup =
    t.observers
    |> List.filter cleanup.observer_cleanup_selected
    |> List.concat_map cleanup.observer_cleanup_hooks

  type observer_counts = {
    active_count : int;
    invalid_count : int;
  }

  type 'observer observer_count_plan = {
    observer_count_active : 'observer -> bool;
    observer_count_invalid : 'observer -> bool;
  }

  let observer_count_plan ~active ~invalid =
    { observer_count_active = active; observer_count_invalid = invalid }

  let increment_count count = if count = max_int then max_int else count + 1

  let observer_counts t _lane plan =
    List.fold_left
      (fun counts observer ->
        {
          active_count =
            (if plan.observer_count_active observer then
               increment_count counts.active_count
             else counts.active_count);
          invalid_count =
            (if plan.observer_count_invalid observer then
               increment_count counts.invalid_count
             else counts.invalid_count);
        })
      { active_count = 0; invalid_count = 0 }
      t.observers

  let observer_counts_active counts = counts.active_count
  let observer_counts_invalid counts = counts.invalid_count

  type ('observer, 'diagnostic) observer_diagnostics = {
    observer_diagnostic_visible : 'observer -> bool;
    observer_diagnostic_value : 'observer -> 'diagnostic;
  }

  let observer_diagnostics ~visible ~diagnostic =
    {
      observer_diagnostic_visible = visible;
      observer_diagnostic_value = diagnostic;
    }

  let collect_observer_diagnostics t _lane diagnostics =
    List.filter_map
      (fun observer ->
        if diagnostics.observer_diagnostic_visible observer then
          Some (diagnostics.observer_diagnostic_value observer)
        else None)
      t.observers

  type 'pending stabilization_pending_plan = {
    pending_release_marks :
      lane_access -> 'pending list -> stabilization_pending_mark_release;
    pending_stage :
      lane_access -> staging -> 'pending list -> stabilization_pending_stage;
  }

  and stabilization_pending_mark_release =
    | Stabilization_pending_mark_release of {
        release_pending_marks : unit -> unit;
      }

  and stabilization_pending_stage =
    | Stabilization_pending_stage of { stage_pending : unit -> unit }

  let stabilization_pending_mark_release ~release =
    Stabilization_pending_mark_release { release_pending_marks = release }

  let stabilization_pending_stage ~stage =
    Stabilization_pending_stage { stage_pending = stage }

  let stabilization_pending_plan ~release_marks ~stage =
    { pending_release_marks = release_marks; pending_stage = stage }

  let run_stabilization_pending_mark_release lane pending plan =
    match plan lane pending with
    | Stabilization_pending_mark_release { release_pending_marks } ->
        release_pending_marks ()

  let run_stabilization_pending_stage lane staging pending plan =
    match plan lane staging pending with
    | Stabilization_pending_stage { stage_pending } -> stage_pending ()

  type ('observer, 'event) stabilization_observer_plan = {
    observer_candidates : lane_access -> 'observer list;
    observer_delivery :
      lane_access ->
      staging ->
      (lane_access, 'observer, 'event) Eta_signal_observer.delivery_collection;
    observer_plan_staged_binds :
      lane_access -> staging -> 'observer list -> staged_bind_planning;
  }

  and staged_bind_planning =
    | Staged_bind_planning of { plan_staged_binds : unit -> unit }

  let staged_bind_planning ~plan =
    Staged_bind_planning { plan_staged_binds = plan }

  let stabilization_observer_plan ~candidates ~delivery ~plan_staged_binds =
    {
      observer_candidates = candidates;
      observer_delivery = delivery;
      observer_plan_staged_binds = plan_staged_binds;
    }

  let run_staged_bind_planning = function
    | Staged_bind_planning { plan_staged_binds } -> plan_staged_binds ()

  type ('bind, 'node, 'hook, 'timer) stabilization_commit_plan = {
    stabilization_commit_staging_plan :
      lane_access -> staging -> ('bind, 'node, 'hook, 'timer) staging_commit_plan;
    stabilization_update_necessity : lane_access -> stabilization_necessity_update;
  }

  and stabilization_necessity_update =
    | Stabilization_necessity_update of { update_necessity : unit -> unit }

  let stabilization_necessity_update ~update =
    Stabilization_necessity_update { update_necessity = update }

  let stabilization_commit_plan ~staging ~update_necessity =
    {
      stabilization_commit_staging_plan = staging;
      stabilization_update_necessity = update_necessity;
    }

  let run_stabilization_necessity_update lane plan =
    match plan lane with
    | Stabilization_necessity_update { update_necessity } ->
        update_necessity ()

  type
    ( 'pending,
      'bind,
      'node,
      'observer,
      'event,
      'hook,
      'timer )
    stabilization_pure =
    {
      pending_plan : 'pending stabilization_pending_plan;
      observer_plan : ('observer, 'event) stabilization_observer_plan;
      commit_plan : ('bind, 'node, 'hook, 'timer) stabilization_commit_plan;
    }

  let stabilization_pure_ops ~pending ~observers ~commit =
    { pending_plan = pending; observer_plan = observers; commit_plan = commit }

  type
    ( 'pending,
      'bind,
      'observer,
      'hook,
      'timer,
      'refresh )
    stabilization_rollback =
    {
      rollback_staging_context :
        lane_access ->
        staging ->
        ('bind, 'hook, 'timer, 'refresh) staging_reset_context;
      mark_observers_failed_without_current :
        lane_access -> 'observer list -> stabilization_observer_failure_mark;
      requeue_pending : lane_access -> 'pending list -> stabilization_pending_requeue;
    }

  and stabilization_pending_requeue =
    | Stabilization_pending_requeue of { requeue_pending : unit -> unit }

  and stabilization_observer_failure_mark =
    | Stabilization_observer_failure_mark of {
        mark_observers_failed_without_current : unit -> unit;
      }

  let stabilization_pending_requeue ~requeue =
    Stabilization_pending_requeue { requeue_pending = requeue }

  let stabilization_observer_failure_mark ~mark =
    Stabilization_observer_failure_mark
      { mark_observers_failed_without_current = mark }

  let stabilization_rollback_ops ~staging
      ~mark_observers_failed_without_current ~requeue_pending =
    {
      rollback_staging_context = staging;
      mark_observers_failed_without_current;
      requeue_pending;
    }

  let run_stabilization_pending_requeue lane pending plan =
    match plan lane pending with
    | Stabilization_pending_requeue { requeue_pending } ->
        requeue_pending ()

  let run_stabilization_observer_failure_mark lane observers plan =
    match plan lane observers with
    | Stabilization_observer_failure_mark
        { mark_observers_failed_without_current } ->
        mark_observers_failed_without_current ()

  type
    ( 'pending,
      'bind,
      'node,
      'observer,
      'event,
      'hook,
      'timer,
      'refresh )
    stabilization_ops =
    {
      classify_graph_error : exn -> Eta_signal_error.graph_error option;
      pure :
        ( 'pending,
          'bind,
          'node,
          'observer,
          'event,
          'hook,
          'timer )
        stabilization_pure;
      rollback :
        ( 'pending,
          'bind,
          'observer,
          'hook,
          'timer,
          'refresh )
        stabilization_rollback;
    }

  let stabilization_ops ~classify_graph_error ~pure ~rollback =
    { classify_graph_error; pure; rollback }

  exception Graph_phase_error of Eta_signal_error.graph_error

  let classify_graph_error ops = function
    | Graph_phase_error error -> Some error
    | exn -> ops.classify_graph_error exn

  let atomic_ops t timer_refresh ops =
    Eta_signal_atomic_pass.ops
      ~reentrant_error:`Reentrant_stabilization
      ~classify_graph_error:(classify_graph_error ops)
      ~advance_generation:(fun _lane ->
        match advance_generation t with
        | Ok () -> ()
        | Error error -> raise (Graph_phase_error error))
      ~begin_staging:(fun _lane -> begin_staging t ~timer_refresh)
      ~drain_pending:(fun _lane -> drain_pending t)
      ~release_pending_marks:(fun lane pending ->
        run_stabilization_pending_mark_release lane pending
          ops.pure.pending_plan.pending_release_marks)
      ~observer_snapshot:(fun lane ->
        let staging = require_active_staging t in
        let delivery = ops.pure.observer_plan.observer_delivery lane staging in
        let observers = ops.pure.observer_plan.observer_candidates lane in
        Eta_signal_observer.delivery_plan delivery ~observers ~capability:Fun.id
          ~make_plan:Eta_signal_atomic_pass.observer_snapshot)
      ~stage_pending:(fun lane pending ->
        run_stabilization_pending_stage lane (require_active_staging t) pending
          ops.pure.pending_plan.pending_stage)
      ~plan_dynamic:(fun lane observers ->
        let plan =
          ops.pure.observer_plan.observer_plan_staged_binds lane
            (require_active_staging t) observers
        in
        run_staged_bind_planning plan)
      ~prepare_commit:(fun lane staging ->
        let context =
          ops.pure.commit_plan.stabilization_commit_staging_plan lane staging
        in
        prepare_staging t lane staging context)
      ~update_necessity:(fun lane ->
        run_stabilization_necessity_update lane
          ops.pure.commit_plan.stabilization_update_necessity)
      ~clear_timer_refresh:(fun _lane -> State.clear_active_timer_refresh t.state)
      ~rollback_staging:(fun lane staging ->
        let context = ops.rollback.rollback_staging_context lane staging in
        reset_staging t lane staging context)
      ~mark_observers_failed:(fun lane observers ->
        run_stabilization_observer_failure_mark lane observers
          ops.rollback.mark_observers_failed_without_current)
      ~requeue_pending:(fun lane pending ->
        run_stabilization_pending_requeue lane pending
          ops.rollback.requeue_pending)
      ~rollback_observers:(fun lane ->
        ops.pure.observer_plan.observer_candidates lane)

  let run_stabilization t capability ~timer_refresh ops =
    Eta_signal_atomic_pass.run t.atomic_pass capability
      (atomic_ops t timer_refresh ops)

  let finish_stabilization t _lane =
    State.clear_active_timer_refresh t.state;
    Eta_signal_atomic_pass.finish_delivering t.atomic_pass

  type stabilization_finish = { mutable delivery_pending : bool }

  let create_stabilization_finish () = { delivery_pending = false }

  let record_stabilization_result finish _lane result =
    Eta_signal_atomic_pass.result result
      ~planning_ok:(fun ~hooks ~events:_ ->
        finish.delivery_pending <- true;
        hooks)
      ~graph_error:(fun ~hooks _ -> hooks)
      ~defect:(fun ~hooks _ _ -> hooks)

  let stabilization_finish_pending finish = finish.delivery_pending

  let finish_recorded_stabilization t lane finish =
    if finish.delivery_pending then (
      finish.delivery_pending <- false;
      finish_stabilization t lane)

  type ('event, 'error) stabilization_delivery_context = {
    delivery_run_pending_cleanup : unit -> (unit, 'error) Eta.Effect.t;
    delivery_run_events : 'event list -> (unit, 'error) Eta.Effect.t;
    delivery_with_lane_access :
      (lane_access -> unit) -> (unit, 'error) Eta.Effect.t;
  }

  let stabilization_delivery_context ~run_pending_cleanup ~run_events
      ~with_lane_access =
    {
      delivery_run_pending_cleanup = run_pending_cleanup;
      delivery_run_events = run_events;
      delivery_with_lane_access = with_lane_access;
    }

  let finish_recorded_stabilization_effect t finish context =
    if stabilization_finish_pending finish then
      context.delivery_with_lane_access (fun lane ->
          finish_recorded_stabilization t lane finish)
    else Eta.Effect.unit

  let stabilization_delivery_ops t finish context =
    Eta_signal_atomic_pass.delivery
      ~run_pending_cleanup:context.delivery_run_pending_cleanup
      ~run_events:context.delivery_run_events
      ~mark_complete:(fun () ->
        context.delivery_with_lane_access (fun lane ->
            bump_counter t lane Callback_delivery_count))
      ~finish:(fun () ->
        finish_recorded_stabilization_effect t finish context)

  let remember_dead_node t _lane dead_node =
    Eta_signal_tombstone_index.insert t.tombstone_counters dead_node
      t.dead_nodes

  let tombstone_counters t = t.tombstone_counters

  let collect_live_node_registry t ~collect_live_nodes ~keep =
    let cells, nodes = collect_live_nodes keep t.all_nodes in
    t.all_nodes <- cells;
    nodes

  let remember_live_node t ~create_weak_node node =
    t.all_nodes <- create_weak_node node :: t.all_nodes

  let create_live_node t scope_ops lifecycle ~dependencies =
    ensure_context t;
    List.iter lifecycle.node_validate_dependency dependencies;
    match next_signal_id t with
    | Error _ as error -> error
    | Ok id -> (
        match allocation_scope t scope_ops with
        | Error _ as error -> error
        | Ok scope ->
            let node = lifecycle.node_create ~id ~scope in
            lifecycle.node_reserve_dependencies node (List.length dependencies);
            List.iter lifecycle.node_reserve_dependents dependencies;
            List.iter
              (fun child ->
                lifecycle.node_attach_dependency ~parent:node ~child)
              dependencies;
            Option.iter (fun scope -> lifecycle.node_add_to_scope scope node) scope;
            remember_live_node t
              ~create_weak_node:lifecycle.node_create_weak
              (lifecycle.node_pack node);
            Ok node)

  let rec invalidate_live_node t lane lifecycle ~invalidate_scope node =
    if lifecycle.invalidation_valid node then (
      let timer_hooks = lifecycle.invalidation_timer_hooks node in
      lifecycle.invalidation_set_invalid node;
      let tombstone = lifecycle.invalidation_tombstone node in
      remember_dead_node t lane tombstone;
      let observer_hooks = lifecycle.invalidation_observer_hooks node in
      let dependents = lifecycle.invalidation_detach_edges node in
      let dependent_hooks =
        List.concat_map
          (invalidate_live_node t lane lifecycle ~invalidate_scope)
          dependents
      in
      let kind_hooks =
        lifecycle.invalidation_kind_hooks ~invalidate_scope node
      in
      timer_hooks @ observer_hooks @ dependent_hooks @ kind_hooks)
    else []

  type ('node, 'weak_node) live_node_registry = {
    registry_collect_live_nodes :
      ('node -> bool) -> 'weak_node list -> 'weak_node list * 'node list;
  }

  let live_node_registry ~collect_live_nodes =
    { registry_collect_live_nodes = collect_live_nodes }

  let live_nodes t _lane registry ~keep =
    collect_live_node_registry t
      ~collect_live_nodes:registry.registry_collect_live_nodes
      ~keep

  type necessary_snapshot = (Eta_signal_id.signal, unit) Hashtbl.t

  let necessary_count snapshot = Hashtbl.length snapshot
  let necessary_mem snapshot id = Hashtbl.mem snapshot id

  type ('observer, 'node) demand_roots = {
    demand_root_demands : 'observer -> bool;
    demand_root_node : 'observer -> 'node;
  }

  let demand_roots ~demand ~root =
    { demand_root_demands = demand; demand_root_node = root }

  type ('observer, 'node, 'weak_node) reachable_plan = {
    reachable_plan_ops : (Eta_signal_id.signal, 'node) reachable_ops;
    reachable_plan_registry : ('node, 'weak_node) live_node_registry;
    reachable_plan_roots : ('observer, 'node) demand_roots;
  }

  let reachable_plan ~ops ~registry ~roots =
    {
      reachable_plan_ops = ops;
      reachable_plan_registry = registry;
      reachable_plan_roots = roots;
    }

  let demand_root_nodes roots observers =
    List.filter_map
      (fun observer ->
        if roots.demand_root_demands observer then
          Some (roots.demand_root_node observer)
        else None)
      observers

  let reachable_live_nodes t lane plan =
    live_nodes t lane plan.reachable_plan_registry ~keep:(fun _ -> true)

  let reachable_root_nodes t plan =
    demand_root_nodes plan.reachable_plan_roots t.observers

  let necessary_ids t lane plan =
    ignore (reachable_live_nodes t lane plan : _ list);
    collect_reachable_ids t lane plan.reachable_plan_ops
      ~roots:(reachable_root_nodes t plan)

  let update_necessity t lane plan =
    let next = necessary_ids t lane plan in
    Core.update_necessary_ids t.core lane next;
    next

  let dead_node_count t _lane = Eta_signal_tombstone_index.length t.dead_nodes

  let iter_dead_nodes t _lane ~f =
    Eta_signal_tombstone_index.iter t.tombstone_counters ~f t.dead_nodes

  let map_dead_nodes t _lane ~f =
    Eta_signal_tombstone_index.map t.tombstone_counters ~f t.dead_nodes
end
module Id = Eta_signal_id
module Signal_snapshot = Graph_algorithms.Snapshot
module Observer_core = Eta_signal_observer
module Observer_snapshot = Observer_core.Snapshot
module Observer_lifecycle = Observer_core.Lifecycle
module Observer_plan = Eta_signal_observer_plan
module Observer_delivery_counters = Eta_signal_observer_delivery
module Node_lifetime = Eta_signal_node
module Demand = Eta_signal_demand
module Scheduler = Eta_signal_scheduler
module Scope = Eta_signal_scope
module Topology = Eta_signal_topology
module Work = Eta_signal_work
module Atomic_pass = Eta_signal_atomic_pass
module Timer = Eta_signal_timer
module Timer_policy = Eta_signal_timer_policy
module Transaction = Eta_signal_transaction

module Cutoff = Eta_signal_cutoff

module type Observer_error = sig
  type t

  val pp : Format.formatter -> t -> unit
end

module No_observer_error = struct
  type t = |

  let pp _ppf (error : t) = match error with _ -> .
end

module type Package_graph = sig
  type 'a signal
  type 'a plan

  type 'a change =
    | Left of 'a
    | Right of 'a
    | Changed of 'a * 'a

  type ('key, 'data, 'map) input_ops = {
    empty : 'map;
    compare_key : 'key -> 'key -> int;
    fold_symmetric_diff :
      'acc.
      'map ->
      'map ->
      on_compare:(unit -> unit) ->
      init:'acc ->
      f:('acc -> 'key -> 'data change -> 'acc) ->
      'acc;
  }

  type ('key, 'output, 'map) output_ops = {
    empty : 'map;
    set : 'key -> 'output -> 'map -> 'map;
    remove : 'key -> 'map -> 'map;
  }

  val stable_family :
    ?data_cutoff:'data Cutoff.t ->
    input:'data_map signal ->
    input_ops:('key, 'data, 'data_map) input_ops ->
    output_ops:('key, 'output, 'output_map) output_ops ->
    build:(key:'key -> data:'data signal -> 'output signal) ->
    unit ->
    'output_map plan

  val install : 'a plan -> 'a signal
end

module Make (Observer_error : Observer_error) () = struct
  type observer_error = Observer_error.t

  let cutoff_equal cutoff published candidate =
    Cutoff.suppress cutoff ~published ~candidate

  let cutoff_or_default = Option.value ~default:Cutoff.phys_equal

  type graph_error = Error.graph_error

  exception Graph_error of graph_error

  type observer_read_error = Error.observer_read_error

  type stabilize_error = observer_error Error.stabilize_error
  type time_error = Error.time_error

  type 'a update = 'a Observer_core.Update.t =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  type keyed_stats = {
    node_count : int;
    committed_child_count : int;
    reconciliation_count : int;
    input_key_comparison_count : int;
    input_diff_event_count : int;
    child_visit_count : int;
    provisional_addition_count : int;
    committed_addition_count : int;
    committed_removal_count : int;
    reconciliation_rollback_count : int;
  }

  type stats = {
    pure_snapshot_commit_count : int;
    callback_delivery_count : int;
    total_node_count : int;
    active_observer_count : int;
    invalid_observer_count : int;
    necessary_node_count : int;
    dead_node_count : int;
    live_dirty_node_count : int;
    recompute_count : int;
    dynamic_scope_invalidations : int;
    nodes_became_necessary : int;
    nodes_became_unnecessary : int;
    lane_waiter_count : int;
    lane_cancelled_waiter_count : int;
    keyed : keyed_stats;
  }

  type dot_scope = [ `Necessary | `All_valid | `All_including_invalid ]

  type dot_options = {
    dot_scope : dot_scope;
    dot_observers : bool;
    dot_timers : bool;
    dot_state : bool;
    dot_dynamic_scopes : bool;
  }

  let default_dot_options =
    {
      dot_scope = `Necessary;
      dot_observers = false;
      dot_timers = false;
      dot_state = false;
      dot_dynamic_scopes = false;
    }

  let pp_graph_error = Error.pp_graph_error
  let pp_observer_read_error = Error.pp_observer_read_error
  let pp_stabilize_error ppf err =
    Error.pp_stabilize_error Observer_error.pp ppf err

  let pp_time_error = Error.pp_time_error

  let default_equal a b = a == b

  let saturating_succ value =
    if value = max_int then max_int else value + 1

  let saturating_add left right =
    if right >= max_int - left then max_int else left + right

  type keyed_counter =
    | Reconciliation_count
    | Input_key_comparison_count
    | Input_diff_event_count
    | Child_visit_count
    | Provisional_addition_count
    | Committed_addition_count
    | Committed_removal_count
    | Reconciliation_rollback_count

  type keyed_counter_state = {
    mutable reconciliation_count : int;
    mutable input_key_comparison_count : int;
    mutable input_diff_event_count : int;
    mutable child_visit_count : int;
    mutable provisional_addition_count : int;
    mutable committed_addition_count : int;
    mutable committed_removal_count : int;
    mutable reconciliation_rollback_count : int;
  }

  let keyed_counters =
    {
      reconciliation_count = 0;
      input_key_comparison_count = 0;
      input_diff_event_count = 0;
      child_visit_count = 0;
      provisional_addition_count = 0;
      committed_addition_count = 0;
      committed_removal_count = 0;
      reconciliation_rollback_count = 0;
    }

  let keyed_counter_value = function
    | Reconciliation_count -> keyed_counters.reconciliation_count
    | Input_key_comparison_count -> keyed_counters.input_key_comparison_count
    | Input_diff_event_count -> keyed_counters.input_diff_event_count
    | Child_visit_count -> keyed_counters.child_visit_count
    | Provisional_addition_count -> keyed_counters.provisional_addition_count
    | Committed_addition_count -> keyed_counters.committed_addition_count
    | Committed_removal_count -> keyed_counters.committed_removal_count
    | Reconciliation_rollback_count ->
        keyed_counters.reconciliation_rollback_count

  let set_keyed_counter counter value =
    match counter with
    | Reconciliation_count -> keyed_counters.reconciliation_count <- value
    | Input_key_comparison_count ->
        keyed_counters.input_key_comparison_count <- value
    | Input_diff_event_count -> keyed_counters.input_diff_event_count <- value
    | Child_visit_count -> keyed_counters.child_visit_count <- value
    | Provisional_addition_count ->
        keyed_counters.provisional_addition_count <- value
    | Committed_addition_count ->
        keyed_counters.committed_addition_count <- value
    | Committed_removal_count -> keyed_counters.committed_removal_count <- value
    | Reconciliation_rollback_count ->
        keyed_counters.reconciliation_rollback_count <- value

  let observer_plan_counters = Observer_plan.create_counters ()
  let observer_delivery_counters = Observer_delivery_counters.create_counters ()

  let bump_keyed_counter counter =
    set_keyed_counter counter (saturating_succ (keyed_counter_value counter))

  let counter_overflow name = raise (Graph_error (`Counter_overflow name))

  let checked_succ name value =
    if value = max_int then counter_overflow name else value + 1

  type signal_id = Id.signal
  type scope_id = Id.scope
  type var_id = Id.var
  type observer_id = Id.observer

  let signal_id_int = Id.signal_int
  let scope_id_int = Id.scope_int
  let var_id_int = Id.var_int
  let observer_id_int = Id.observer_int

  let signal_id_label = Id.signal_label
  let dead_signal_id_label = Id.dead_signal_label
  let scope_id_label = Id.scope_label
  let var_id_label = Id.var_label
  let observer_id_label = Id.observer_label

  type weak_packed_signal = Graph_algorithms.Weak_cell.t

  type timer_catch_up_policy = Timer_policy.catch_up_policy =
    | Catch_up_once_per_wake
    | Catch_up_coalesced

  type scope = (scope_id, packed_signal, packed_signal) Scope.t

  and packed_signal = P : 'a signal -> packed_signal

  and edge = {
    parent : packed_signal;
    child : packed_signal;
    mutable parent_slot : int;
    mutable child_slot : int;
    dynamic : bool;
  }

  and 'a keyed_change =
    | Keyed_left of 'a
    | Keyed_right of 'a
    | Keyed_changed of 'a * 'a

  and keyed_structural_event =
    | Keyed_detached of scope
    | Keyed_invalidated of scope
    | Keyed_attached of scope

  and ('key, 'value, 'map) keyed_map_ops = {
    keyed_empty : 'map;
    keyed_find_opt : 'key -> 'map -> 'value option;
    keyed_set : 'key -> 'value -> 'map -> 'map;
    keyed_remove : 'key -> 'map -> 'map;
    keyed_fold : 'acc. ('key -> 'value -> 'acc -> 'acc) -> 'map -> 'acc -> 'acc;
  }

  and ('key, 'data, 'map) keyed_input_ops = {
    keyed_input_empty : 'map;
    keyed_compare_key : 'key -> 'key -> int;
    keyed_fold_symmetric_diff :
      'acc.
      'map ->
      'map ->
      on_compare:(unit -> unit) ->
      init:'acc ->
      f:('acc -> 'key -> 'data keyed_change -> 'acc) ->
      'acc;
  }

  and ('key, 'output, 'map) keyed_output_ops = {
    keyed_output_empty : 'map;
    keyed_output_set : 'key -> 'output -> 'map -> 'map;
    keyed_output_remove : 'key -> 'map -> 'map;
  }

  and scheduler_visit_state =
    | Scheduler_unseen
    | Scheduler_visiting
    | Scheduler_done

  and 'a signal = {
    id : signal_id;
    equal : 'a -> 'a -> bool;
    mutable kind : 'a kind;
    snapshot : (signal_id, 'a) Signal_snapshot.t Transaction.staged;
    mutable dirty : bool;
    dependencies : edge Topology.vector;
    dependents : edge Topology.vector;
    dependency_index : (int, edge) Hashtbl.t;
    mutable demand : int;
    mutable scheduled : bool;
    mutable schedule_previous : packed_signal option;
    mutable schedule_next : packed_signal option;
    mutable schedule_attempt_local : bool;
    mutable schedule_attempt_removed : bool;
    mutable schedule_visit_generation : int;
    mutable schedule_visit_state : scheduler_visit_state;
    mutable signal_observers : packed_observer list;
    mutable dirty_listeners : (unit -> unit) list;
    mutable computing : bool;
    mutable seen_generation : int;
    mutable changed_seen : bool;
    mutable computed_generation : int;
    scope : scope option;
    lifetime : Node_lifetime.t;
    mutable timer : timer_node option;
    mutable timer_reconcile_linked : bool;
    mutable timer_reconcile_token : int;
    mutable timer_reconcile_previous : packed_signal option;
    mutable timer_reconcile_next : packed_signal option;
  }

  and scheduler_frame = {
    frame_node : packed_signal;
    mutable frame_next_dependency : int;
  }

  and _ kind =
    | Const : 'a -> 'a kind
    | Var : 'a var -> 'a kind
    | Map : 'a signal * ('a -> 'b) -> 'b kind
    | Map2 : 'a signal * 'b signal * ('a -> 'b -> 'c) -> 'c kind
    | Map3 :
        'a signal * 'b signal * 'c signal * ('a -> 'b -> 'c -> 'd)
        -> 'd kind
    | Map4 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * ('a -> 'b -> 'c -> 'd -> 'e)
        -> 'e kind
    | Map5 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f)
        -> 'f kind
    | Map6 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g)
        -> 'g kind
    | Map7 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * 'g signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h)
        -> 'h kind
    | Map8 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * 'g signal
        * 'h signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i)
        -> 'i kind
    | Map9 :
        'a signal
        * 'b signal
        * 'c signal
        * 'd signal
        * 'e signal
        * 'f signal
        * 'g signal
        * 'h signal
        * 'i signal
        * ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h -> 'i -> 'j)
        -> 'j kind
    | All : 'a signal list -> 'a list kind
    | Bind : ('a, 'b) bind -> 'b kind
    | Keyed :
        ('key, 'data, 'output, 'data_map, 'output_map, 'child_map) keyed
        -> 'output_map kind

  and ('a, 'b) bind = {
    source : 'a signal;
    selector : 'a -> 'b signal;
    mutable owner : 'b signal option;
    snapshot : ('a, 'b signal, scope) Bind.snapshot Transaction.staged;
  }

  and ('key, 'data, 'output) keyed_child = {
    keyed_child_key : 'key;
    keyed_child_scope : scope;
    keyed_child_source : 'data var;
    keyed_child_data : 'data signal;
    keyed_child_output : 'output signal;
    keyed_child_listener : unit -> unit;
  }

  and ('key, 'data, 'output, 'data_map, 'output_map, 'child_map) keyed_plan = {
    keyed_plan_input : 'data_map;
    mutable keyed_plan_children : 'child_map;
    mutable keyed_plan_output : 'output_map;
    mutable keyed_plan_removals : ('key, 'data, 'output) keyed_child list;
    mutable keyed_plan_additions : ('key, 'data, 'output) keyed_child list;
    mutable keyed_plan_updates : ('key, 'data, 'output) keyed_child list;
    mutable keyed_plan_provisional_scopes : scope list;
    mutable keyed_plan_processed : 'child_map;
  }

  and ('key, 'data, 'output, 'data_map, 'output_map, 'child_map) keyed = {
    keyed_input : 'data_map signal;
    keyed_data_cutoff : 'data Cutoff.t;
    keyed_builder : key:'key -> data:'data signal -> 'output signal;
    keyed_data_ops : ('key, 'data, 'data_map) keyed_input_ops;
    keyed_output_ops : ('key, 'output, 'output_map) keyed_output_ops;
    keyed_child_ops :
      ('key, ('key, 'data, 'output) keyed_child, 'child_map) keyed_map_ops;
    keyed_raw_input : 'data_map Transaction.staged;
    keyed_children : 'child_map Transaction.staged;
    mutable keyed_affected : 'child_map;
    mutable keyed_owner : 'output_map signal option;
    mutable keyed_preflight : unit -> unit;
    mutable keyed_record_event : keyed_structural_event -> unit;
    mutable keyed_pending :
      ('key, 'data, 'output, 'data_map, 'output_map, 'child_map) keyed_plan option;
  }

  and packed_bind = B : ('a, 'b) bind -> packed_bind

  and 'a var = {
    var_id : var_id;
    var_equal : 'a -> 'a -> bool;
    source_value : 'a Transaction.staged;
    graph_value : 'a Transaction.staged;
    mutable queued : bool;
    mutable updating : bool;
    mutable watchers : weak_packed_signal list;
  }

  and packed_var = V : 'a var -> packed_var

  and observer_after_ack_action = unit -> unit

  and 'a observer_delivery_state =
    ('a, observer_after_ack_action) Observer_core.Delivery.t

  and 'a observer_live_state = {
    observer_snapshot :
      ('a, observer_after_ack_action) Observer_snapshot.t
      Transaction.staged;
    mutable obs_owner : packed_observer option;
    mutable obs_on_finish : (Observer_lifecycle.finish_reason -> unit) list;
  }

  and 'a observer_state =
    ('a observer_live_state, 'a Observer_core.Value.t) Observer_lifecycle.t

  and 'a observer = {
    obs_id : observer_id;
    obs_signal : 'a signal;
    obs_equal : 'a -> 'a -> bool;
    obs_callback :
      Observer_core.Delivery.token ->
      'a update ->
      (unit, observer_error) Effect.t;
    mutable obs_state : 'a observer_state;
    mutable obs_candidate : bool;
    mutable obs_candidate_previous : packed_observer option;
    mutable obs_candidate_next : packed_observer option;
  }

  and packed_observer = O : 'a observer -> packed_observer

  and timer_refresh_operation =
    | Refresh_operation : 'a var * 'a Timer_policy.refresh_spec -> timer_refresh_operation

  and timer_transition =
    | Set_source : 'a var * 'a -> timer_transition
    | Advance_due of int
    | Finish of Timer_policy.finish_plan

  and timer_node = timer_refresh_operation Timer.node

  and timer_update = {
    timer_catch_up_policy : timer_catch_up_policy;
    timer_update : 'err. timer_node -> int -> missed:int -> (unit, 'err) Effect.t;
  }

  and dead_signal = {
    dead_id : signal_id;
    dead_kind : string;
    dead_initialized : bool;
    dead_dirty : bool;
    dead_computing : bool;
    dead_dependency_ids : signal_id list;
    dead_dependency_count : int;
    dead_dependent_count : int;
    dead_scope_id : scope_id option;
    dead_scope_owner : signal_id option;
    dead_scope_parent : scope_id option;
    dead_scope_valid : bool option;
    dead_timer : Timer_policy.debug_snapshot option;
    dead_keyed_child_count : int option;
  }

  and 'a source_timer_update = {
    source_timer_update :
      'err. timer_node -> int -> missed:int -> 'a var -> (unit, 'err) Effect.t;
  }

  open Observer_core.Delivery

  let signal_valid signal = Node_lifetime.is_live signal.lifetime

  let edge_parent edge = edge.parent
  let edge_child edge = edge.child

  let signal_dependencies signal =
    Topology.fold signal.dependencies ~init:[] ~f:(fun dependencies edge ->
        edge.child :: dependencies)
    |> List.rev

  let signal_dependents signal =
    Topology.fold signal.dependents ~init:[] ~f:(fun dependents edge ->
        edge.parent :: dependents)
    |> List.rev

  let packed_signal_id (P signal) = signal.id
  let scope_owner_id scope = packed_signal_id (Scope.owner scope)

  module Scope_validation = Scope.Make_validation (struct
    type node_id = signal_id
    type nonrec scope_id = scope_id
    type owner = packed_signal
    type node = packed_signal

    let node_id (P signal) = signal.id
    let valid (P signal) = signal_valid signal
    let scope (P signal) = signal.scope

    let children (P signal) =
      match signal.kind with
      | Bind _ -> []
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
      | Map7 _ | Map8 _ | Map9 _ | All _ | Keyed _ ->
          signal_dependencies signal
  end)

  module Graph_edge_node = struct
    type nonrec packed = packed_signal
    type t = Packed : 'a signal -> t

    let pack (Packed signal) = P signal
  end

  let graph_edge_node signal = Graph_edge_node.Packed signal

  let graph_node_identity =
    Graph.node_identity ~id:(fun (P signal) -> signal.id)
      ~equal_id:(fun left right -> signal_id_int left = signal_id_int right)

  let dirty_ops =
    Graph.dirty_ops ~identity:graph_node_identity
      ~dirty:(fun (P signal) -> signal.dirty)
      ~set_dirty:(fun (P signal) dirty -> signal.dirty <- dirty)

  let compute_ops =
    Graph.compute_ops ~node:(fun (P signal) -> graph_edge_node signal)
      ~pack:Graph_edge_node.pack
      ~seen_generation:(fun (Graph_edge_node.Packed signal) ->
        signal.seen_generation)
      ~set_seen_generation:(fun (Graph_edge_node.Packed signal) generation ->
        signal.seen_generation <- generation)
      ~changed_seen:(fun (Graph_edge_node.Packed signal) ->
        signal.changed_seen)
      ~set_changed_seen:(fun (Graph_edge_node.Packed signal) changed ->
        signal.changed_seen <- changed)
      ~computing:(fun (Graph_edge_node.Packed signal) -> signal.computing)
      ~set_computing:(fun (Graph_edge_node.Packed signal) computing ->
        signal.computing <- computing)
      ~computed_generation:(fun (Graph_edge_node.Packed signal) ->
        signal.computed_generation)
      ~set_computed_generation:(fun (Graph_edge_node.Packed signal) generation ->
        signal.computed_generation <- generation)

  let publish_initial_current staged value =
    Transaction.publish_current Transaction.initialize_current staged value

  let publish_source_current staged value =
    Transaction.publish_current Transaction.source_publication staged value

  let publish_observer_current staged value =
    Transaction.publish_current Transaction.observer_publication staged value

  let publish_timer_current staged value =
    Transaction.publish_current Transaction.timer_lifecycle staged value

  type disposal_hook = Cleanup.hook

  type timer_refresh_context =
    (Runtime_contract.t, packed_signal * bool) Timer_policy.refresh_context

  type graph =
    ( packed_var,
      packed_bind,
      packed_signal,
      disposal_hook,
      timer_node,
      timer_refresh_context,
      packed_observer,
      weak_packed_signal,
      dead_signal,
      (scope_id, packed_signal, packed_signal) Scope.context )
    Graph.t

  type ('key, 'value) keyed_child_tree =
    | Keyed_child_empty
    | Keyed_child_node of {
        left : ('key, 'value) keyed_child_tree;
        key : 'key;
        value : 'value;
        right : ('key, 'value) keyed_child_tree;
        height : int;
      }

  let keyed_child_height = function
    | Keyed_child_empty -> 0
    | Keyed_child_node node -> node.height

  let keyed_child_node left key value right =
    Keyed_child_node
      {
        left;
        key;
        value;
        right;
        height =
          1
          + Int.max (keyed_child_height left) (keyed_child_height right);
      }

  let keyed_child_balance left key value right =
    let left_height = keyed_child_height left in
    let right_height = keyed_child_height right in
    if left_height > right_height + 1 then
      match left with
      | Keyed_child_node left_node
        when keyed_child_height left_node.right
             > keyed_child_height left_node.left -> (
          match left_node.right with
          | Keyed_child_node inner ->
              keyed_child_node
                (keyed_child_node left_node.left left_node.key
                   left_node.value inner.left)
                inner.key inner.value
                (keyed_child_node inner.right key value right)
          | Keyed_child_empty -> keyed_child_node left key value right)
      | Keyed_child_node left_node ->
          keyed_child_node left_node.left left_node.key left_node.value
            (keyed_child_node left_node.right key value right)
      | Keyed_child_empty -> keyed_child_node left key value right
    else if right_height > left_height + 1 then
      match right with
      | Keyed_child_node right_node
        when keyed_child_height right_node.left
             > keyed_child_height right_node.right -> (
          match right_node.left with
          | Keyed_child_node inner ->
              keyed_child_node
                (keyed_child_node left key value inner.left)
                inner.key inner.value
                (keyed_child_node inner.right right_node.key right_node.value
                   right_node.right)
          | Keyed_child_empty -> keyed_child_node left key value right)
      | Keyed_child_node right_node ->
          keyed_child_node
            (keyed_child_node left key value right_node.left)
            right_node.key right_node.value right_node.right
      | Keyed_child_empty -> keyed_child_node left key value right
    else keyed_child_node left key value right

  let rec keyed_child_find_opt compare key = function
    | Keyed_child_empty -> None
    | Keyed_child_node node ->
        let order = compare key node.key in
        if order = 0 then Some node.value
        else if order < 0 then keyed_child_find_opt compare key node.left
        else keyed_child_find_opt compare key node.right

  let rec keyed_child_set compare key value tree =
    match tree with
    | Keyed_child_empty -> keyed_child_node tree key value tree
    | Keyed_child_node node ->
        let order = compare key node.key in
        if order = 0 then keyed_child_node node.left key value node.right
        else if order < 0 then
          keyed_child_balance
            (keyed_child_set compare key value node.left)
            node.key node.value node.right
        else
          keyed_child_balance node.left node.key node.value
            (keyed_child_set compare key value node.right)

  let rec keyed_child_min_binding = function
    | Keyed_child_empty -> invalid_arg "Eta_signal: empty keyed child map"
    | Keyed_child_node { left = Keyed_child_empty; key; value; _ } ->
        (key, value)
    | Keyed_child_node node -> keyed_child_min_binding node.left

  let rec keyed_child_remove compare key tree =
    match tree with
    | Keyed_child_empty -> tree
    | Keyed_child_node node ->
        let order = compare key node.key in
        if order < 0 then
          keyed_child_balance
            (keyed_child_remove compare key node.left)
            node.key node.value node.right
        else if order > 0 then
          keyed_child_balance node.left node.key node.value
            (keyed_child_remove compare key node.right)
        else
          match (node.left, node.right) with
          | Keyed_child_empty, Keyed_child_empty -> Keyed_child_empty
          | Keyed_child_empty, Keyed_child_node _ -> node.right
          | Keyed_child_node _, Keyed_child_empty -> node.left
          | Keyed_child_node _, Keyed_child_node _ ->
              let successor_key, successor_value =
                keyed_child_min_binding node.right
              in
              keyed_child_balance node.left successor_key successor_value
                (keyed_child_remove compare successor_key node.right)

  let rec keyed_child_fold f tree acc =
    match tree with
    | Keyed_child_empty -> acc
    | Keyed_child_node node ->
        let acc = keyed_child_fold f node.left acc in
        let acc = f node.key node.value acc in
        keyed_child_fold f node.right acc

  let keyed_child_ops compare_key =
    {
      keyed_empty = Keyed_child_empty;
      keyed_find_opt = keyed_child_find_opt compare_key;
      keyed_set = keyed_child_set compare_key;
      keyed_remove = keyed_child_remove compare_key;
      keyed_fold = keyed_child_fold;
    }

  let graph =
    Graph.create ~create_scope_context:Scope.create_context ()

  let topology_counters = Topology.create_counters ()
  let demand_counters = Demand.create_counters ()
  let scheduler_counters = Scheduler.create_counters ()
  let work_counters = Work.create_counters ()
  let scheduler = Scheduler.create scheduler_counters
  let work = Work.create work_counters
  let necessary_nodes = Hashtbl.create 16
  let necessary_bind_nodes = Hashtbl.create 8
  let timer_nodes = Hashtbl.create 8
  let timer_reconcile_head = ref None

  let link_timer_reconcile (P signal as packed) =
    if Hashtbl.mem timer_nodes signal.id then (
      signal.timer_reconcile_token <- signal.timer_reconcile_token + 1;
      if not signal.timer_reconcile_linked then (
        signal.timer_reconcile_linked <- true;
        signal.timer_reconcile_previous <- None;
        signal.timer_reconcile_next <- !timer_reconcile_head;
        (match !timer_reconcile_head with
         | None -> ()
         | Some (P head) -> head.timer_reconcile_previous <- Some packed);
        timer_reconcile_head := Some packed))

  let unlink_timer_reconcile (P signal) =
    if signal.timer_reconcile_linked then (
      signal.timer_reconcile_linked <- false;
      (match signal.timer_reconcile_previous with
       | None -> timer_reconcile_head := signal.timer_reconcile_next
       | Some (P previous) ->
           previous.timer_reconcile_next <- signal.timer_reconcile_next);
      (match signal.timer_reconcile_next with
       | None -> ()
       | Some (P next) ->
           next.timer_reconcile_previous <- signal.timer_reconcile_previous);
      signal.timer_reconcile_previous <- None;
      signal.timer_reconcile_next <- None)

  let unlink_timer_reconcile_token (P signal) token =
    if signal.timer_reconcile_linked && signal.timer_reconcile_token = token
    then unlink_timer_reconcile (P signal)

  let timer_reconcile_pending () = !timer_reconcile_head

  let timer_reconcile_next (P signal) = signal.timer_reconcile_next

  let scheduler_access =
    Scheduler.access
      ~queued:(fun (P signal) -> signal.scheduled)
      ~set_queued:(fun (P signal) scheduled -> signal.scheduled <- scheduled)
      ~previous:(fun (P signal) -> signal.schedule_previous)
      ~set_previous:(fun (P signal) previous ->
        signal.schedule_previous <- previous)
      ~next:(fun (P signal) -> signal.schedule_next)
      ~set_next:(fun (P signal) next -> signal.schedule_next <- next)
      ~attempt_local:(fun (P signal) -> signal.schedule_attempt_local)
      ~set_attempt_local:(fun (P signal) local ->
        signal.schedule_attempt_local <- local)
      ~attempt_removed:(fun (P signal) -> signal.schedule_attempt_removed)
      ~set_attempt_removed:(fun (P signal) removed ->
        signal.schedule_attempt_removed <- removed)
      ~pack:Fun.id ~unpack:Fun.id

  let scope_ops =
    Graph.scope_ops ~current:Scope.current
      ~require_valid_current:Scope.require_valid_current
      ~with_current:{ run_current = Scope.with_current }

  let pack_weak_signal signal = P signal
  let weak_packed_signal (P signal) = Graph_algorithms.Weak_cell.create signal
  let weak_packed_signal_value cell =
    Graph_algorithms.Weak_cell.value ~pack:pack_weak_signal cell

  let collect_live_weak_signals keep cells =
    Graph_algorithms.Weak_cell.collect ~pack:pack_weak_signal ~keep cells

  let live_signal_registry =
    Graph.live_node_registry ~collect_live_nodes:collect_live_weak_signals

  let all_nodes_unlocked lane =
    Graph.live_nodes graph lane live_signal_registry
      ~keep:(fun (P signal) -> signal_valid signal)

  let children_with_scope_owner signal children =
    Scope.children_with_scope_owner
      ~owner_valid:(fun (P owner) -> signal_valid owner)
      ~owner_node:(fun owner -> owner)
      signal.scope children

  let reachable_ops =
    Graph.reachable_ops ~id:(fun (P signal) -> signal.id)
      ~valid:(fun (P signal) -> signal_valid signal)
      ~children:(fun (P signal) ->
        children_with_scope_owner signal (signal_dependencies signal))

  let source_watchers_unlocked source =
    let cells, watchers =
      collect_live_weak_signals (fun (P signal) -> signal_valid signal) source.watchers
    in
    source.watchers <- cells;
    watchers

  let kind_name : type a. a kind -> string = function
    | Const _ -> "const"
    | Var _ -> "var"
    | Map _ -> "map"
    | Map2 _ -> "map2"
    | Map3 _ -> "map3"
    | Map4 _ -> "map4"
    | Map5 _ -> "map5"
    | Map6 _ -> "map6"
    | Map7 _ -> "map7"
    | Map8 _ -> "map8"
    | Map9 _ -> "map9"
    | All _ -> "all"
    | Bind _ -> "bind"
    | Keyed _ -> "keyed_mapi"

  let graph_context_error_message = Graph.context_error_message

  let ensure_graph_context () = Graph.ensure_context graph

  let graph_lane_depth_local : int Runtime_contract.local =
    Runtime_contract.create_local ~inheritance:Fiber_local ()

  type graph_lane = Graph.lane_access

  type event =
    (graph_lane, (unit, observer_error) Effect.t, stabilize_error)
    Observer_core.Delivery_event.t

  let with_graph_lane_access f =
    Graph.with_lane_access graph
      ~leaf_name:"Eta_signal.with_graph_lane_sync"
      ~depth_local:graph_lane_depth_local
      ~hooks:
        (Graph.lane_hooks
           ~note_waiter_enqueued:ignore
           ~note_waiter_compaction:ignore)
      ~after_acquired:(fun () -> Effect.unit)
      f

  let with_graph_lane_sync f =
    with_graph_lane_access (fun _lane -> f ())

  (* Synchronous constructors mutate graph indexes without entering the graph
     lane. Keep this path same-domain, non-effectful, and callback-free;
     effectful public operations must use [with_graph_lane_sync]. *)
  let[@inline always] graph_result_or_raise = function
    | Ok value -> value
    | Error err -> raise (Graph_error err)

  let next_var_id () =
    ensure_graph_context ();
    graph_result_or_raise (Graph.next_var_id graph)

  let next_observer_id () =
    ensure_graph_context ();
    graph_result_or_raise (Graph.next_observer_id graph)

  let new_scope owner =
    Scope.create
      ~id:(graph_result_or_raise (Graph.next_scope_id graph))
      ~owner:(P owner) ~parent:owner.scope

  let current_generation lane = Graph.generation graph lane

  let scheduler_visiting lane signal =
    signal.schedule_visit_generation = current_generation lane
    && signal.schedule_visit_state = Scheduler_visiting

  let schedule_signal packed =
    if Scheduler.admit scheduler scheduler_access packed then
      Work.admit work Work.Scheduler

  let release_scheduler_work count =
    for _ = 1 to count do
      Work.release work Work.Scheduler
    done

  let demand_ops lane =
    Demand.ops
      ~demand:(fun (P signal) -> signal.demand)
      ~set_demand:(fun (P signal) demand -> signal.demand <- demand)
      ~iter_dependencies:(fun (P signal) visit ->
        Topology.iter signal.dependencies visit)
      ~dependency:edge_child
      ~on_boundary:(fun (P signal as packed) ~necessary ->
        if Option.is_some signal.timer then (
          Demand.note_timer_desired_state_transition demand_counters;
          link_timer_reconcile packed);
        if necessary then (
          if Option.is_some signal.timer then
            Work.admit work Work.Timer_reconciliation;
          Hashtbl.replace necessary_nodes (signal_id_int signal.id) packed;
          (match signal.kind with
          | Bind _ ->
              Hashtbl.replace necessary_bind_nodes
                (signal_id_int signal.id) packed
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Keyed _ ->
              ());
          if
            signal.dirty
            && not (scheduler_visiting lane signal)
            && signal.computed_generation <> current_generation lane
          then schedule_signal packed;
          Graph.bump_counter graph lane Graph.Nodes_became_necessary)
        else (
          let attempt_active = Scheduler.attempt_active scheduler in
          if
            Scheduler.remove scheduler scheduler_access packed
            && not attempt_active
          then
            Work.release work Work.Scheduler;
          if Option.is_some signal.timer then
            Work.release work Work.Timer_reconciliation;
          Hashtbl.remove necessary_nodes (signal_id_int signal.id);
          Hashtbl.remove necessary_bind_nodes (signal_id_int signal.id);
          Graph.bump_counter graph lane Graph.Nodes_became_unnecessary))

  let adjust_demand lane signal delta =
    match Demand.adjust demand_counters (demand_ops lane) (P signal) delta with
    | Ok () -> ()
    | Error `Overflow -> counter_overflow "demand count"
    | Error `Underflow ->
        invalid_arg "Eta_signal: demand reference count underflow"

  let adjust_demand_many lane roots delta =
    match Demand.adjust_many demand_counters (demand_ops lane) roots delta with
    | Ok () -> ()
    | Error `Overflow -> counter_overflow "demand count"
    | Error `Underflow ->
        invalid_arg "Eta_signal: demand reference count underflow"

  let check_demand lane signal delta =
    match Demand.check (demand_ops lane) (P signal) delta with
    | Ok () -> ()
    | Error `Overflow -> counter_overflow "demand count"
    | Error `Underflow ->
        invalid_arg "Eta_signal: demand reference count underflow"

  let attach_edge ?lane ~dynamic parent child =
    let child_id = signal_id_int child.id in
    match
      if dynamic then Hashtbl.find_opt parent.dependency_index child_id
      else None
    with
    | Some edge -> edge
    | None ->
        let edge =
          {
            parent = P parent;
            child = P child;
            parent_slot = -1;
            child_slot = -1;
            dynamic;
          }
        in
        Topology.reserve_additional parent.dependencies 1;
        Topology.reserve_additional child.dependents 1;
        (match lane with
         | Some lane when parent.demand > 0 -> check_demand lane child 1
         | Some _ | None -> ());
        if dynamic then Hashtbl.add parent.dependency_index child_id edge;
        edge.parent_slot <- Topology.append parent.dependencies edge;
        edge.child_slot <- Topology.append child.dependents edge;
        if dynamic then Topology.note_dynamic_insert topology_counters
        else Topology.note_static_insert topology_counters;
        if parent.demand > 0 then (
          match lane with
          | Some lane -> adjust_demand lane child 1
          | None ->
              invalid_arg
                "Eta_signal: necessary edge insertion requires graph lane");
        edge

  let remove_edge lane edge =
    let (P parent) = edge.parent in
    let (P child) = edge.child in
    if parent.demand > 0 then adjust_demand lane child (-1);
    let parent_slot = edge.parent_slot in
    let _, moved_parent = Topology.remove parent.dependencies parent_slot in
    Option.iter
      (fun moved ->
        moved.parent_slot <- parent_slot;
        Topology.note_slot_repair topology_counters)
      moved_parent;
    let child_slot = edge.child_slot in
    let _, moved_child = Topology.remove child.dependents child_slot in
    Option.iter
      (fun moved ->
        moved.child_slot <- child_slot;
        Topology.note_slot_repair topology_counters)
      moved_child;
    if edge.dynamic then (
      match Hashtbl.find_opt parent.dependency_index (signal_id_int child.id) with
      | Some indexed when indexed == edge ->
          Hashtbl.remove parent.dependency_index (signal_id_int child.id)
      | None | Some _ -> ());
    edge.parent_slot <- -1;
    edge.child_slot <- -1;
    Topology.note_indexed_removal topology_counters

  let detach_dependency lane parent child =
    match
      Hashtbl.find_opt parent.dependency_index (signal_id_int child.id)
    with
    | None -> ()
    | Some edge -> remove_edge lane edge

  let attach_dependency lane parent child =
    ignore (attach_edge ~lane ~dynamic:true parent child : edge)

  let attach_new_keyed_dependency lane parent child =
    ignore (attach_edge ~lane ~dynamic:true parent child : edge)

  let attach_initial_packed_dependency parent (P child) =
    ignore (attach_edge ~dynamic:false parent child : edge)

  let mark_self_dirty lane (P signal as packed) =
    Graph.mark_dirty graph lane dirty_ops packed;
    if
      signal.demand > 0
      && not signal.computing
      && not (scheduler_visiting lane signal)
      && signal.computed_generation <> current_generation lane
    then schedule_signal packed

  let add_dirty_listener signal listener =
    signal.dirty_listeners <- listener :: signal.dirty_listeners

  let remove_dirty_listener signal listener =
    signal.dirty_listeners <-
      List.filter (fun candidate -> candidate != listener)
        signal.dirty_listeners

  let mark_timer_refresh_dirty lane staging packed =
    Graph.mark_timer_refresh_dirty graph lane staging
      ~mark:(fun () -> Graph.mark_dirty graph lane dirty_ops packed)
      ~record:(fun context ->
        Timer_policy.set_refresh_dirty_items context
          (Graph.mark_dirty_recording_previous graph lane dirty_ops
             (Timer_policy.refresh_dirty_items context)
             packed));
    let P signal = packed in
    if
      signal.demand > 0
      && not signal.computing
      && not (scheduler_visiting lane signal)
      && signal.computed_generation <> current_generation lane
    then schedule_signal packed

  let remove_var_watcher source signal =
    source.watchers <-
      List.filter
        (fun cell ->
          match weak_packed_signal_value cell with
          | None -> false
          | Some (P candidate) -> signal_valid candidate && candidate.id <> signal.id)
        source.watchers

  let stage_var_graph_value (type a) lane staging (var : a var) value =
    Graph.stage_cell graph lane staging var.graph_value value

  let stage_var_source_value (type a) lane staging (var : a var) value =
    Graph.stage_cell graph lane staging var.source_value value

  let effective_var_value (type a) (var : a var) =
    Graph.read_effective graph var.graph_value

  let remember_computed lane staging (P signal) =
    Graph.remember_computed graph lane staging compute_ops (P signal)

  let signal_current_snapshot signal =
    Transaction.current signal.snapshot

  let signal_effective_snapshot signal =
    Graph.read_effective graph signal.snapshot

  let effective_signal_version signal =
    Signal_snapshot.version (signal_effective_snapshot signal)

  let version_ops =
    Graph.version_ops ~identity:graph_node_identity
      ~version:(fun (P signal) -> effective_signal_version signal)

  let update_signal_staging lane staging signal f =
    Graph.update_cell graph lane staging signal.snapshot f

  let signal_staged_in_active_transaction lane staging signal =
    Graph.staged_in_active_transaction graph lane staging signal.snapshot

  let stage_signal lane staging signal value =
    update_signal_staging lane staging signal (fun snapshot ->
        let current = signal_current_snapshot signal in
        Signal_snapshot.publish
          ~advance_version:(checked_succ "signal version")
          ~current snapshot value)

  let dependency_versions lane dependencies =
    Graph.version_snapshot graph lane version_ops dependencies

  let dependencies_changed lane signal dependencies =
    Graph.versions_changed graph lane version_ops
      ~current:
        (Signal_snapshot.dependency_versions
           (signal_current_snapshot signal))
      dependencies

  let stage_dependency_versions lane staging signal dependencies =
    update_signal_staging lane staging signal (fun snapshot ->
        Signal_snapshot.with_dependency_versions snapshot
          (dependency_versions lane dependencies))

  let effective_signal_value signal =
    match Signal_snapshot.value (signal_effective_snapshot signal) with
    | Some value -> value
    | None -> raise (Graph_error `Invalid_scope)

  let observer_active_live_state observer =
    Observer_lifecycle.active_live observer.obs_state

  let observer_current_snapshot live =
    Transaction.current live.observer_snapshot

  let observer_effective_snapshot live =
    Graph.read_effective graph live.observer_snapshot

  let observer_delivery_pending snapshot =
    Observer_core.Delivery.pending (Observer_snapshot.delivery snapshot)

  let observer_candidate_head = ref None

  let link_observer_candidate observer =
    if observer.obs_candidate then false
    else (
      observer.obs_candidate <- true;
      observer.obs_candidate_previous <- None;
      observer.obs_candidate_next <- !observer_candidate_head;
      (match !observer_candidate_head with
       | Some (O head) ->
           head.obs_candidate_previous <- Some (O observer)
       | None -> ());
      observer_candidate_head := Some (O observer);
      true)

  let unlink_observer_candidate observer =
    if not observer.obs_candidate then false
    else (
      observer.obs_candidate <- false;
      let previous = observer.obs_candidate_previous in
      let next = observer.obs_candidate_next in
      (match previous with
       | Some (O previous_observer) ->
           previous_observer.obs_candidate_next <- next
       | None -> observer_candidate_head := next);
      (match next with
       | Some (O next_observer) ->
           next_observer.obs_candidate_previous <- previous
       | None -> ());
      observer.obs_candidate_previous <- None;
      observer.obs_candidate_next <- None;
      true)

  let observer_candidates () =
    let rec collect candidates = function
      | Some (O observer as packed) ->
          collect (packed :: candidates) observer.obs_candidate_next
      | None -> List.rev candidates
    in
    collect [] !observer_candidate_head

  let observer_has_pending_delivery (O observer) =
    match observer_active_live_state observer with
    | Some live
      when observer_delivery_pending (observer_current_snapshot live) ->
        true
    | Some _ | None -> false

  let mark_observer_candidate observer =
    if link_observer_candidate observer then
      Work.admit work Work.Observer_delivery

  let clear_observer_candidate observer =
    if unlink_observer_candidate observer
       && not (observer_has_pending_delivery (O observer))
    then Work.release work Work.Observer_delivery

  let finish_observer_candidate observer =
    if not (observer_has_pending_delivery (O observer)) then
      clear_observer_candidate observer

  let set_observer_current live snapshot =
    let was_pending =
      observer_delivery_pending (observer_current_snapshot live)
    in
    let is_pending = observer_delivery_pending snapshot in
    publish_observer_current live.observer_snapshot snapshot;
    if (not was_pending) && is_pending then (
      match live.obs_owner with
      | Some (O observer) -> mark_observer_candidate observer
      | None -> Work.admit work Work.Observer_delivery)
    else if was_pending && not is_pending then (
      match live.obs_owner with
      | Some (O observer) when observer.obs_candidate ->
          ignore (unlink_observer_candidate observer);
          Work.release work Work.Observer_delivery
      | Some _ | None -> Work.release work Work.Observer_delivery)

  let observer_active (O observer) =
    Observer_lifecycle.active observer.obs_state

  let observer_delivery_candidate (O observer) =
    observer.obs_candidate
    ||
    match observer_active_live_state observer with
    | None -> false
    | Some live ->
        Observer_core.Delivery.pending
          (Observer_snapshot.delivery (observer_current_snapshot live))

  let observer_demands_signal (O observer) =
    Observer_lifecycle.demands observer.obs_state

  let observer_roots selected observers =
    List.filter_map
      (fun (O observer as packed) ->
        if selected packed then Some (P observer.obs_signal) else None)
      observers

  let observer_demand_roots =
    Graph.demand_roots ~demand:observer_demands_signal
      ~root:(fun (O observer) -> P observer.obs_signal)

  let observer_active_roots observers =
    observer_roots observer_active observers

  let observer_identity =
    Graph.observer_identity ~same:(fun (O candidate) (O target) ->
        candidate.obs_id = target.obs_id)

  let observer_reference_demand_roots signal =
    P signal
    :: (match signal.scope with
       | None -> []
       | Some scope ->
           let (P owner) = Scope.owner scope in
           [ P owner ])

  let remove_observer lane observer =
    adjust_demand_many lane (observer_reference_demand_roots observer.obs_signal) (-1);
    observer.obs_signal.signal_observers <-
      List.filter
        (fun (O candidate) -> candidate.obs_id <> observer.obs_id)
        observer.obs_signal.signal_observers;
    Graph.remove_observer graph lane observer_identity (O observer)

  let observer_finish_hooks live reason =
    List.map (fun hook () -> hook reason) live.obs_on_finish

  let observer_activation_port () =
    Observer_core.activation_port
      ~state:(fun observer -> observer.obs_state)
      ~set_state:(fun observer state -> observer.obs_state <- state)

  let observer_lifecycle_port lane =
    Observer_core.lifecycle_port
      ~state:(fun observer -> observer.obs_state)
      ~set_state:(fun observer state -> observer.obs_state <- state)
      ~value:(fun live ->
        Observer_snapshot.value (observer_current_snapshot live))
      ~finish_hooks:observer_finish_hooks ~remove:(remove_observer lane)

  let run_after_ack_actions_unlocked actions =
    List.iter (fun action -> action ()) actions

  let observer_delivery_port () =
    Observer_core.delivery_port
      ~live:(fun (_lane : graph_lane) observer ->
        observer_active_live_state observer)
      ~snapshot:(fun (_lane : graph_lane) live ->
        observer_current_snapshot live)
      ~set_snapshot:(fun (_lane : graph_lane) live snapshot ->
        set_observer_current live snapshot)
      ~run_after_ack:(fun (_lane : graph_lane) actions ->
        run_after_ack_actions_unlocked actions)
      ~acknowledgement_attempt:(fun _lane ->
        Observer_delivery_counters.note_acknowledgement_attempt
          observer_delivery_counters)
      ~acknowledgement_success:(fun _lane ->
        Observer_delivery_counters.note_acknowledgement_success
          observer_delivery_counters)
      ~release:(fun _lane ->
        Observer_delivery_counters.note_release observer_delivery_counters)

  let release_observer_delivery_work observer =
    let had_candidate = observer.obs_candidate in
    let had_pending = observer_has_pending_delivery (O observer) in
    ignore (unlink_observer_candidate observer);
    if had_candidate || had_pending then
      Work.release work Work.Observer_delivery;
    match observer_active_live_state observer with
    | Some live when had_pending ->
        publish_observer_current live.observer_snapshot
          (Observer_snapshot.clear_pending_delivery
             (observer_current_snapshot live))
    | Some _ | None -> ()

  let dispose_observer_unlocked lane observer =
    release_observer_delivery_work observer;
    Observer_core.dispose_observer (observer_lifecycle_port lane) observer

  let invalidate_observer_unlocked lane observer =
    release_observer_delivery_work observer;
    Observer_core.invalidate_observer (observer_lifecycle_port lane) observer

  let dispose_signal_observers lane signal =
    Graph.collect_observer_cleanup_hooks graph lane
      (Graph.observer_cleanup
         ~selected:(fun (O observer) -> observer.obs_signal.id = signal.id)
         ~cleanup:(fun (O observer) ->
           invalidate_observer_unlocked lane observer))

  let validate_dependency (P signal) =
    if not (signal_valid signal) then raise (Graph_error `Invalid_scope)

  let timer_state_generation = Timer_policy.state_generation

  let timer_current_snapshot timer =
    Transaction.current (Timer.snapshot_cell timer)

  let timer_effective_snapshot timer =
    Graph.read_effective graph (Timer.snapshot_cell timer)

  let set_timer_current_snapshot timer snapshot =
    Graph.publish_or_stage graph Transaction.timer_lifecycle
      (Timer.snapshot_cell timer) snapshot

  let set_timer_current_state timer timer_state =
    let snapshot = timer_current_snapshot timer in
    set_timer_current_snapshot timer
      (Timer_policy.snapshot_with_state snapshot timer_state)

  let update_timer_staging lane staging timer f =
    let snapshot_cell = Timer.snapshot_cell timer in
    Graph.update_cell graph lane staging snapshot_cell f

  let timer_current_state timer =
    Timer_policy.snapshot_state (timer_current_snapshot timer)

  let timer_generation timer =
    timer_state_generation (timer_current_state timer)

  let timer_state_label = Timer_policy.state_label

  let timer_has_staged_refresh timer =
    Graph.timer_has_staged_refresh graph timer
      ~refresh_token:Timer_policy.refresh_token
      ~staged_token:Timer.staged_refresh_token

  let timer_effective_state timer =
    if timer_has_staged_refresh timer then
      Timer_policy.snapshot_state (timer_effective_snapshot timer)
    else timer_current_state timer

  let timer_state_port =
    Timer.state_port ~effective:timer_effective_state
      ~current:timer_current_state ~set_current:set_timer_current_state

  let timer_needs_start timer =
    Timer_policy.needs_start ~effective_state:(timer_effective_state timer)
      ~current_state:(timer_current_state timer)

  let timer_runtime_mismatch _runtime_contract _timer =
    (`Runtime_mismatch : graph_error)

  let ensure_timer_runtime timer runtime_contract =
    graph_result_or_raise
      (Timer.validate_runtime ~runtime_mismatch:timer_runtime_mismatch
         runtime_contract timer)

  let timer_running_generation timer =
    Timer_policy.state_running_generation (timer_effective_state timer)

  let timer_has_cancel timer =
    Timer_policy.state_has_cancel (timer_effective_state timer)

  let add_int_capped = Timer_policy.add_int_capped

  let timer_set_next_due_state = Timer_policy.state_set_next_due

  let remember_timer_refresh_timer lane staging timer =
    Graph.remember_timer_refresh_timer graph lane staging timer
      ~refresh_token:Timer_policy.refresh_token
      ~staged_token:Timer.staged_refresh_token
      ~set_staged_token:Timer.set_staged_refresh_token
      ~stage_refresh_token:(fun timer token ->
        update_timer_staging lane staging timer (fun snapshot ->
            Timer_policy.snapshot_with_on_demand_refresh_token snapshot token))

  let stage_timer_state_unlocked lane staging timer state =
    remember_timer_refresh_timer lane staging timer;
    update_timer_staging lane staging timer (fun snapshot ->
        Timer_policy.snapshot_with_state snapshot state)

  let timer_mark_unneeded_unlocked ?(cancel_running = true) timer =
    Timer.mark_node_unneeded
      ~advance_generation:(checked_succ "timer generation")
      ~cancel_running timer_state_port timer

  let timer_invalidation_hooks timer =
    match
      Timer_policy.stop ~advance_generation:(checked_succ "timer generation")
        ~cancel_running:true (timer_current_state timer)
    with
    | None -> []
    | Some plan ->
        Timer_policy.stop_plan_result plan
          ~plan:(fun ~state ~cancel_hooks ->
            (fun () -> set_timer_current_state timer state) :: cancel_hooks)

  let node_lifecycle ?equal ~dirty kind =
    Graph.node_lifecycle ~validate_dependency
      ~create:(fun ~id ~scope ->
        {
          id;
          equal = Option.value equal ~default:default_equal;
          kind;
          snapshot = Transaction.create_staged Signal_snapshot.empty;
          dirty;
          dependencies = Topology.create_vector ();
          dependents = Topology.create_vector ();
          dependency_index = Hashtbl.create 4;
          demand = 0;
          scheduled = false;
          schedule_previous = None;
          schedule_next = None;
          schedule_attempt_local = false;
          schedule_attempt_removed = false;
          schedule_visit_generation = -1;
          schedule_visit_state = Scheduler_unseen;
          signal_observers = [];
          dirty_listeners = [];
          computing = false;
          seen_generation = -1;
          changed_seen = false;
          computed_generation = -1;
          scope;
          lifetime = Node_lifetime.create ();
          timer = None;
          timer_reconcile_linked = false;
          timer_reconcile_token = 0;
          timer_reconcile_previous = None;
          timer_reconcile_next = None;
        })
      ~reserve_dependencies:(fun signal count ->
        Topology.reserve_additional signal.dependencies count)
      ~reserve_dependents:(fun (P child) ->
        Topology.reserve_additional child.dependents 1)
      ~attach_dependency:(fun ~parent ~child ->
        attach_initial_packed_dependency parent child)
      ~add_to_scope:(fun scope signal -> Scope.add_node scope (P signal))
      ~pack:(fun signal -> P signal)
      ~create_weak:weak_packed_signal

  let new_signal ?(dirty = true) ?equal kind dependencies =
    graph_result_or_raise
      (Graph.create_live_node graph scope_ops
         (node_lifecycle ?equal ~dirty kind)
         ~dependencies)

  let new_var ?(equal = default_equal) value =
    {
      var_id = next_var_id ();
      var_equal = equal;
      source_value = Transaction.create_staged value;
      graph_value = Transaction.create_staged value;
      queued = false;
      updating = false;
      watchers = [];
    }

  let watch_var source =
    let signal = new_signal ~equal:source.var_equal (Var source) [] in
    source.watchers <- weak_packed_signal (P signal) :: source.watchers;
    signal

  let new_const ?equal value =
    let signal = new_signal ?equal ~dirty:false (Const value) [] in
    publish_initial_current signal.snapshot
      (Signal_snapshot.initialized value);
    signal

  let timer_debug_snapshot timer =
    let snapshot = Timer_policy.debug_snapshot (timer_effective_state timer) in
    Timer_policy.debug_snapshot_with_generation snapshot
      (timer_generation timer)

  let timer_tombstone timer = timer_debug_snapshot timer

  let signal_tombstone (P signal) =
    let dead_scope_id, dead_scope_owner, dead_scope_parent, dead_scope_valid =
      match signal.scope with
      | None -> (None, None, None, None)
      | Some scope ->
          ( Some (Scope.id scope),
            Some (scope_owner_id scope),
            Option.map (fun parent -> Scope.id parent) (Scope.parent scope),
            Some (Scope.valid scope) )
    in
    let snapshot = signal_current_snapshot signal in
    let dead_keyed_child_count =
      match signal.kind with
      | Keyed keyed ->
          Some
            (keyed.keyed_child_ops.keyed_fold
               (fun _ _ count -> saturating_succ count)
               (Transaction.current keyed.keyed_children) 0)
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
          None
    in
    {
      dead_id = signal.id;
      dead_kind = kind_name signal.kind;
      dead_initialized = Signal_snapshot.is_initialized snapshot;
      dead_dirty = signal.dirty;
      dead_computing = signal.computing;
      dead_dependency_ids =
        List.map
          (fun (P dependency) -> dependency.id)
          (signal_dependencies signal);
      dead_dependency_count = Topology.length signal.dependencies;
      dead_dependent_count = Topology.length signal.dependents;
      dead_scope_id;
      dead_scope_owner;
      dead_scope_parent;
      dead_scope_valid;
      dead_timer = Option.map timer_tombstone signal.timer;
      dead_keyed_child_count;
    }

  let detach_node_edges lane signal =
    let dependents = signal_dependents signal in
    while Topology.length signal.dependencies > 0 do
      remove_edge lane
        (Topology.get signal.dependencies
           (Topology.length signal.dependencies - 1))
    done;
    while Topology.length signal.dependents > 0 do
      remove_edge lane
        (Topology.get signal.dependents
           (Topology.length signal.dependents - 1))
    done;
    Topology.note_invalidated_node topology_counters;
    dependents

  let node_invalidation lane =
    Graph.node_invalidation
      ~valid:(fun (P signal) -> signal_valid signal)
      ~set_invalid:(fun (P signal) ->
        ignore (Node_lifetime.invalidate signal.lifetime : bool))
      ~timer_hooks:(fun (P signal as packed) ->
        match signal.timer with
        | None -> []
        | Some timer ->
            Hashtbl.remove timer_nodes signal.id;
            unlink_timer_reconcile packed;
            timer_invalidation_hooks timer)
      ~tombstone:signal_tombstone
      ~observer_hooks:(fun (P signal) -> dispose_signal_observers lane signal)
      ~detach_edges:(fun (P signal) -> detach_node_edges lane signal)
      ~kind_hooks:(fun ~invalidate_scope (P signal) ->
        signal.dirty_listeners <- [];
        match signal.kind with
        | Var source ->
            remove_var_watcher source signal;
            []
        | Bind bind -> (
            match Bind.inner_scope (Transaction.current bind.snapshot) with
            | None -> []
            | Some scope -> invalidate_scope scope)
        | Keyed keyed ->
            keyed.keyed_child_ops.keyed_fold
              (fun _ child hooks ->
                remove_dirty_listener child.keyed_child_output
                  child.keyed_child_listener;
                invalidate_scope child.keyed_child_scope @ hooks)
              (Transaction.current keyed.keyed_children) []
        | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
        | Map7 _ | Map8 _ | Map9 _ | All _ ->
            [])

  let rec invalidate_scope lane scope =
    match Scope.invalidate scope with
    | None -> []
    | Some nodes ->
        Graph.bump_counter graph lane Graph.Dynamic_scope_invalidations;
        List.concat_map (invalidate_node lane) nodes

  and invalidate_node lane packed =
    Graph.invalidate_live_node graph lane (node_invalidation lane)
      ~invalidate_scope:(invalidate_scope lane) packed

  let make_bind ?equal source selector =
    let bind =
      {
        source;
        selector;
        owner = None;
        snapshot = Transaction.create_staged Bind.empty;
      }
    in
    let signal = new_signal ?equal (Bind bind) [ P source ] in
    bind.owner <- Some signal;
    signal

  let current_or_raise signal =
    match Signal_snapshot.value (signal_current_snapshot signal) with
    | Some value -> value
    | None -> raise (Graph_error `Invalid_scope)

  let signal_commit (P signal) =
    Graph.staged_signal_commit ~valid:(signal_valid signal) ~cell:signal.snapshot
      ~commit:(fun () -> signal.dirty <- false)

  let stage_bind_switch (type a b) lane staging (bind : (a, b) bind)
      source_value inner scope =
    Graph.stage_bind_switch graph lane staging (B bind) bind.snapshot
      ~source_value ~inner ~scope

  let bind_current_snapshot (type a b) (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot =
    Transaction.current bind.snapshot

  module Scope_invalidation = Scope.Make_invalidation (struct
    type nonrec node_id = signal_id
    type nonrec scope_id = scope_id
    type nonrec owner = packed_signal
    type nonrec node = packed_signal

    let node_id (P signal) = signal.id
    let equal_node_id left right = signal_id_int left = signal_id_int right
    let valid (P signal) = signal_valid signal
    let dependents (P signal) = signal_dependents signal

    let nested_scope (P signal) =
      match signal.kind with
      | Bind bind -> Bind.inner_scope (bind_current_snapshot bind)
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Keyed _ ->
          None
  end)

  let bind_effective_snapshot (type a b) (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot =
    Graph.read_effective graph bind.snapshot

  let bind_staged_snapshot (type a b) lane staging (bind : (a, b) bind) :
      (a, b signal, scope) Bind.snapshot option =
    Graph.staged_value graph lane staging bind.snapshot

  let bind_staged_switch (type a b) lane staging (bind : (a, b) bind) :
      (a, b signal, scope, b signal) Bind.staged_switch =
    Bind.staged_switch ~owner:bind.owner
      ~current:(bind_current_snapshot bind)
      ~staged:(bind_staged_snapshot lane staging bind)

  let packed_bind_staged_switch lane staging (B bind) =
    Bind.pack_staged_switch
      (Bind.staged_switch
         ~owner:(Option.map (fun owner -> P owner) bind.owner)
         ~current:(bind_current_snapshot bind)
         ~staged:(bind_staged_snapshot lane staging bind))

  let bind_switch_lifecycle lane =
    Bind.staged_switch_lifecycle
      ~detach_old_inner:(detach_dependency lane)
      ~invalidate_scope:(invalidate_scope lane)
      ~attach_new_inner:(attach_dependency lane)

  let collect_scope_invalidations_into ?exclude_signal_id seen collected scope =
    Scope_invalidation.collect ?exclude_node_id:exclude_signal_id seen
      collected scope

  let preflight_timer_stop timer =
    Timer.preflight_stop ~advance_generation:(checked_succ "timer generation")
      timer_state_port timer

  let preflight_timer_start timer =
    Timer.preflight_start ~advance_generation:(checked_succ "timer generation")
      timer_state_port timer

  type staged_bind_invalidation_view = {
    invalidated_ids : (signal_id, unit) Hashtbl.t;
    invalidated_nodes : packed_signal list;
  }

  let staged_bind_invalidates view (P signal) =
    match view.invalidated_nodes with
    | [] -> false
    | _ :: _ -> Hashtbl.mem view.invalidated_ids signal.id

  let preflight_signal_commit lane staging invalidations (P signal) =
    if
      signal_valid signal
      && not (staged_bind_invalidates invalidations (P signal))
      && signal_staged_in_active_transaction lane staging signal
    then
      let current = signal_current_snapshot signal in
      let staged = signal_effective_snapshot signal in
      Signal_snapshot.preflight_commit_version
        ~advance_version:(checked_succ "signal version")
        ~current ~staged

  let collect_staged_bind_invalidations lane staging =
    let invalidated_ids = Hashtbl.create 16 in
    let invalidated_nodes = ref [] in
    let plan =
      Graph.staged_bind_invalidation_plan
        ~init:(invalidated_ids, invalidated_nodes)
        ~staged_switch:(packed_bind_staged_switch lane staging)
        ~collect_old_scope:(fun (seen, collected) ~owner scope ->
          let P owner_signal = owner in
          collect_scope_invalidations_into ~exclude_signal_id:owner_signal.id
            seen collected scope;
          (seen, collected))
    in
    let (invalidated_ids, invalidated_nodes) =
      graph_result_or_raise
        (Graph.collect_staged_bind_switch_invalidations graph lane staging plan)
    in
    { invalidated_ids; invalidated_nodes = !invalidated_nodes }

  let discard_invalid_staged_binds lane staging invalidations =
    let hooks = ref [] in
    let discarded = ref false in
    Graph.iter_staged_binds graph lane staging ~f:(fun (B bind) ->
        match bind.owner with
        | Some owner
          when (not (signal_valid owner))
               || staged_bind_invalidates invalidations (P owner) ->
            let staged = bind_staged_snapshot lane staging bind in
            if Option.is_some staged then (
              discarded := true;
              (match
                 Bind.rollback_staged_switch ~staged
                   (bind_switch_lifecycle lane)
               with
              | Ok bind_hooks -> hooks := List.rev_append bind_hooks !hooks
              | Error `Invalid_scope -> ());
              Graph.discard_cell graph lane staging bind.snapshot;
              Graph.discard_cell graph lane staging owner.snapshot)
        | Some _ | None -> ());
    if !hooks <> [] then
      Graph.remember_pure_disposal_hooks graph lane staging (List.rev !hooks);
    !discarded

  type packed_keyed =
    | Packed_keyed :
        'output_map signal
        * ('key, 'data, 'output, 'data_map, 'output_map, 'child_map) keyed
        -> packed_keyed

  let pending_keyed = Hashtbl.create 16

  let packed_keyed_owner (Packed_keyed (owner, _)) = P owner

  let compare_keyed_owner_scope_then_id left right =
    let (P left) = packed_keyed_owner left in
    let (P right) = packed_keyed_owner right in
    match Int.compare (Scope.depth left.scope) (Scope.depth right.scope) with
    | 0 -> Int.compare (signal_id_int left.id) (signal_id_int right.id)
    | order -> order

  let pending_keyed_nodes _lane =
    Hashtbl.fold (fun _ packed plans -> packed :: plans) pending_keyed []
    |> List.sort compare_keyed_owner_scope_then_id

  let rollback_keyed_plan lane (Packed_keyed (owner, keyed)) =
    match keyed.keyed_pending with
    | None -> []
    | Some plan ->
        bump_keyed_counter Reconciliation_rollback_count;
        keyed.keyed_pending <- None;
        Hashtbl.remove pending_keyed owner.id;
        List.concat_map
          (invalidate_scope lane)
          plan.keyed_plan_provisional_scopes

  let rollback_pending_keyed lane plans =
    let hooks = List.concat_map (rollback_keyed_plan lane) plans in
    hooks

  let discard_keyed_plan lane staging
      (Packed_keyed (owner, keyed) as packed) =
    match keyed.keyed_pending with
    | None -> []
    | Some plan ->
        Graph.discard_cell graph lane staging owner.snapshot;
        Graph.discard_cell graph lane staging keyed.keyed_raw_input;
        Graph.discard_cell graph lane staging keyed.keyed_children;
        List.iter
          (fun child ->
            Graph.discard_cell graph lane staging
              child.keyed_child_source.source_value;
            Graph.discard_cell graph lane staging
              child.keyed_child_source.graph_value)
          plan.keyed_plan_updates;
        rollback_keyed_plan lane packed

  let extend_keyed_invalidations plans invalidations =
    let invalidated_nodes = ref invalidations.invalidated_nodes in
    List.iter
      (fun (Packed_keyed (owner, keyed)) ->
        if not (staged_bind_invalidates invalidations (P owner)) then
          match keyed.keyed_pending with
          | None -> ()
          | Some plan ->
              List.iter
                (fun child ->
                  collect_scope_invalidations_into
                    ~exclude_signal_id:owner.id
                    invalidations.invalidated_ids invalidated_nodes
                    child.keyed_child_scope)
                plan.keyed_plan_removals)
      plans;
    { invalidations with invalidated_nodes = !invalidated_nodes }

  let discard_retired_keyed_plans lane staging invalidations =
    let retired, _active =
      List.partition
        (fun packed ->
          let (P owner) = packed_keyed_owner packed in
          (not (signal_valid owner))
          || staged_bind_invalidates invalidations (packed_keyed_owner packed))
        (pending_keyed_nodes lane)
    in
    let hooks =
      List.concat_map (discard_keyed_plan lane staging) retired
    in
    if hooks <> [] then
      Graph.remember_pure_disposal_hooks graph lane staging hooks;
    retired <> []

  let rec discard_invalid_dynamic_work lane staging invalidations =
    let discarded_binds =
      discard_invalid_staged_binds lane staging invalidations
    in
    let discarded_keyed =
      discard_retired_keyed_plans lane staging invalidations
    in
    if discarded_binds || discarded_keyed then
      discard_invalid_dynamic_work lane staging invalidations

  let preflight_keyed_plan (Packed_keyed (owner, keyed)) =
    match keyed.keyed_pending with
    | None -> ()
    | Some plan ->
        keyed.keyed_preflight ();
        if not (signal_valid owner) then raise (Graph_error `Invalid_scope);
        List.iter
          (fun child ->
            if
              (not (Scope.valid child.keyed_child_scope))
              || not (signal_valid child.keyed_child_output)
            then raise (Graph_error `Invalid_scope);
            match
              Scope_validation.validate_inner ~scope:child.keyed_child_scope
                (P child.keyed_child_output)
            with
            | Ok () -> ()
            | Error `Invalid_scope -> raise (Graph_error `Invalid_scope))
          plan.keyed_plan_additions

  let record_keyed_event keyed event =
    try keyed.keyed_record_event event with _ -> ()

  let commit_keyed_removals lane (Packed_keyed (owner, keyed)) =
    match keyed.keyed_pending with
    | None -> []
    | Some plan ->
        let hooks = ref [] in
        List.rev plan.keyed_plan_removals
        |> List.iter (fun child ->
               bump_keyed_counter Committed_removal_count;
               record_keyed_event keyed (Keyed_detached child.keyed_child_scope);
               remove_dirty_listener child.keyed_child_output
                 child.keyed_child_listener;
               detach_dependency lane owner child.keyed_child_output;
               hooks :=
                 !hooks
                 @ invalidate_scope lane child.keyed_child_scope;
               record_keyed_event keyed
                 (Keyed_invalidated child.keyed_child_scope));
        !hooks

  let commit_keyed_additions lane (Packed_keyed (owner, keyed)) =
    match keyed.keyed_pending with
    | None -> ()
    | Some plan ->
        List.rev plan.keyed_plan_additions
        |> List.iter (fun child ->
               bump_keyed_counter Committed_addition_count;
               attach_new_keyed_dependency lane owner child.keyed_child_output;
               add_dirty_listener child.keyed_child_output
                 child.keyed_child_listener;
               record_keyed_event keyed (Keyed_attached child.keyed_child_scope))

  let finish_keyed_commit (Packed_keyed (owner, keyed)) =
    match keyed.keyed_pending with
    | None -> ()
    | Some plan ->
        keyed.keyed_affected <-
          keyed.keyed_child_ops.keyed_fold
            (fun key processed affected ->
              match keyed.keyed_child_ops.keyed_find_opt key affected with
              | Some current when current == processed ->
                  keyed.keyed_child_ops.keyed_remove key affected
              | Some _ | None -> affected)
            plan.keyed_plan_processed keyed.keyed_affected;
        keyed.keyed_pending <- None;
        Hashtbl.remove pending_keyed owner.id

  let commit_keyed_plans lane plans =
    let hooks = List.concat_map (commit_keyed_removals lane) plans in
    List.iter (commit_keyed_additions lane) plans;
    List.iter finish_keyed_commit plans;
    hooks

  let preflight_queued_timer_reconciliation () =
    let rec walk (P signal as packed) =
      (match signal.timer with
       | Some timer ->
           if Hashtbl.mem timer_nodes signal.id then
             if signal.demand > 0 then preflight_timer_start timer
             else preflight_timer_stop timer
       | None -> ());
      match timer_reconcile_next packed with
      | None -> ()
      | Some next -> walk next
    in
    Option.iter walk (timer_reconcile_pending ())

  let signal_effective_children (type a) (signal : a signal) :
      packed_signal list =
    match signal.kind with
    | Bind bind ->
        Bind.dependencies ~source:(P bind.source)
          ~inner_dependency:(fun inner -> P inner)
          (bind_effective_snapshot bind)
    | Keyed keyed -> (
        match keyed.keyed_pending with
        | None -> signal_dependencies signal
        | Some keyed_plan ->
            let children =
              keyed.keyed_child_ops.keyed_fold
                (fun _ child dependencies ->
                  P child.keyed_child_output :: dependencies)
                keyed_plan.keyed_plan_children []
              |> List.rev
            in
            P keyed.keyed_input :: children)
    | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
    | Map7 _ | Map8 _ | Map9 _ | All _ ->
        signal_dependencies signal

  let staged_bind_switch_pending lane staging (B bind) =
    match bind_staged_snapshot lane staging bind with
    | None -> false
    | Some staged -> (
        match (Bind.inner (bind_current_snapshot bind), Bind.inner staged) with
        | None, None -> false
        | Some current_inner, Some staged_inner ->
            signal_id_int current_inner.id <> signal_id_int staged_inner.id
        | None, Some _ | Some _, None -> true)

  (* Bind-switch demand boundaries apply during commit, after preflight, so
     the reconcile queue cannot see them yet. Reserve timer capacity for the
     staged world directly: starts follow the staged branch (the attach
     cascade), stops follow the current branch for timers whose demand
     crosses to zero (the detach cascade). Capacity checks are pure, so
     shared visits are deduplicated only to bound work. *)
  let preflight_staged_bind_timers lane staging invalidations =
    let start_visited = Hashtbl.create 8 in
    let stop_visited = Hashtbl.create 8 in
    let walk ~visited ~children ~on_timer root =
      let rec go (P signal as packed) =
        let key = signal_id_int signal.id in
        if
          (not (Hashtbl.mem visited key))
          && signal_valid signal
          && not (staged_bind_invalidates invalidations packed)
        then (
          Hashtbl.replace visited key ();
          on_timer packed;
          List.iter go (children packed))
      in
      go root
    in
    Graph.iter_staged_binds graph lane staging ~f:(fun (B bind) ->
        match (bind.owner, staged_bind_switch_pending lane staging (B bind)) with
        | Some owner, true when owner.demand > 0 -> (
            (match Bind.inner (bind_current_snapshot bind) with
             | None -> ()
             | Some inner ->
                 walk ~visited:stop_visited
                   ~children:(fun (P signal) -> signal_dependencies signal)
                   ~on_timer:(fun (P signal) ->
                     if signal.demand = 1 then
                       Option.iter preflight_timer_stop signal.timer)
                   (P inner));
            match bind_staged_snapshot lane staging bind with
            | None -> ()
            | Some staged -> (
                match Bind.inner staged with
                | None -> ()
                | Some inner ->
                    walk ~visited:start_visited
                      ~children:(fun (P signal) ->
                        signal_effective_children signal)
                      ~on_timer:(fun (P signal) ->
                        Option.iter preflight_timer_start signal.timer)
                      (P inner)))
        | _ -> ())

  let preflight_commit_staging lane staging =
    Graph.staged_preflight ~preflight:(fun () ->
        let keyed_plans = pending_keyed_nodes lane in
        let invalidations =
          collect_staged_bind_invalidations lane staging
          |> extend_keyed_invalidations keyed_plans
        in
        discard_invalid_dynamic_work lane staging invalidations;
        let active_keyed = pending_keyed_nodes lane in
        List.iter preflight_keyed_plan active_keyed;
        List.iter
          (fun (P signal) ->
            Option.iter preflight_timer_stop signal.timer)
          invalidations.invalidated_nodes;
        preflight_queued_timer_reconciliation ();
        preflight_staged_bind_timers lane staging invalidations;
        Graph.iter_computed graph lane staging
          ~f:(preflight_signal_commit lane staging invalidations))

  let remember_pure_disposal_hooks lane staging hooks =
    Graph.remember_pure_disposal_hooks graph lane staging hooks

  let remember_timer_refresh_disposal_hooks lane staging hooks =
    Graph.remember_timer_refresh_disposal_hooks graph lane staging hooks

  let queue_var_unlocked (type a) lane (source : a var) =
    if not source.queued then (
      source.queued <- true;
      Work.admit work Work.Sources;
      Graph.enqueue_pending graph lane (V source))

  let set_var_source_unlocked (type a) lane (source : a var) value =
    publish_source_current source.source_value value;
    queue_var_unlocked lane source

  let stage_timer_source_value (type a) lane staging (source : a var) value =
    let graph_value = effective_var_value source in
    stage_var_source_value lane staging source value;
    if not (source.var_equal graph_value value) then (
      stage_var_graph_value lane staging source value;
      List.iter
        (mark_timer_refresh_dirty lane staging)
        (source_watchers_unlocked source))

  let timer_finish_unlocked timer =
    Timer.finish_node ~advance_generation:(checked_succ "timer generation")
      timer_state_port timer

  let stage_timer_transition lane staging timer = function
    | Set_source (source, value) ->
        stage_timer_source_value lane staging source value
    | Advance_due next_due_ms ->
        stage_timer_state_unlocked lane staging timer
          (timer_set_next_due_state (timer_effective_state timer)
             (Some next_due_ms))
    | Finish plan ->
        Timer_policy.finish_plan_result plan ~plan:(fun ~state ~cancel_hooks ->
            stage_timer_state_unlocked lane staging timer state;
            remember_timer_refresh_disposal_hooks lane staging cancel_hooks)

  let timer_refresh_action source = function
    | Timer_policy.Refresh_set value -> Set_source (source, value)
    | Timer_policy.Refresh_advance_due next_due_ms -> Advance_due next_due_ms
    | Timer_policy.Refresh_finish plan -> Finish plan

  let timer_refresh_plan timer now_ms (Refresh_operation (source, spec)) =
    Timer_policy.refresh_actions_for_spec
      ~advance_generation:(checked_succ "timer generation")
      ~state:(timer_effective_state timer)
      ~current_value:(effective_var_value source) ~now_ms spec
    |> List.map (timer_refresh_action source)

  let stage_timer_refresh_operation lane staging timer now_ms operation =
    List.iter
      (stage_timer_transition lane staging timer)
      (timer_refresh_plan timer now_ms operation)

  let clear_timer_refresh_timer_staging timer =
    Timer.set_staged_refresh_token timer (-1)

  let timer_refresh_commit timer =
    Graph.staged_timer_commit ~commit:(fun () ->
        clear_timer_refresh_timer_staging timer)

  let staging_reset_context lane staging =
    Graph.staging_reset_context
      ~rollback_extensions:(fun _staging ->
        if Scheduler.attempt_active scheduler then
          Scheduler.rollback_attempt scheduler scheduler_access
          |> release_scheduler_work;
        rollback_pending_keyed lane (pending_keyed_nodes lane))
      ~rollback_bind:(fun staging (B bind) ->
        Graph.staged_bind_rollback
          ~staged:(bind_staged_snapshot lane staging bind)
          ~lifecycle:(bind_switch_lifecycle lane))
      ~rollback_timer_refresh_dirty:(fun _staging context ->
        Graph.staged_timer_refresh_dirty_rollback ~rollback:(fun () ->
            Graph.restore_dirty graph lane dirty_ops
              (Timer_policy.refresh_dirty_items context);
            Timer_policy.clear_refresh_dirty_items context))
      ~clear_timer_refresh_timer:(fun _staging timer ->
        Graph.staged_timer_reset ~reset:(fun () ->
            clear_timer_refresh_timer_staging timer))

  let staging_commit_plan lane _staging =
    Graph.staging_commit_plan
      ~preflight:(preflight_commit_staging lane)
      ~binds:
        (Graph.staging_bind_commit_plan
           ~commit:(fun staging (B bind) ->
             Graph.staged_bind_commit
               ~switch:(bind_staged_switch lane staging bind)
               ~lifecycle:(bind_switch_lifecycle lane)))
      ~signals:
        (Graph.staging_signal_commit_plan
           ~commit:(fun _staging signal -> signal_commit signal))
      ~timers:
        (Graph.staging_timer_commit_plan
           ~commit:(fun _staging timer -> timer_refresh_commit timer))
      ~finalize:(fun () ->
        let hooks = commit_keyed_plans lane (pending_keyed_nodes lane) in
        Scheduler.commit_attempt scheduler scheduler_access
        |> release_scheduler_work;
        hooks)

  let requeue_if_needed lane (V var as packed) =
    if not var.queued then (
      var.queued <- true;
      Work.admit work Work.Sources;
      Graph.enqueue_pending graph lane packed)

  let mark_failed_without_current (lane : graph_lane) (O observer) =
    Observer_core.mark_failed_without_current (observer_delivery_port ()) lane
      observer

  let next_timer_refresh_token_unlocked lane =
    graph_result_or_raise (Graph.next_timer_refresh_token graph lane)

  let stage_pending_var lane staging (V var) =
    let graph_value = Transaction.current var.graph_value in
    let source_value = Transaction.current var.source_value in
    if not (var.var_equal graph_value source_value) then (
      stage_var_graph_value lane staging var source_value;
      let watchers = source_watchers_unlocked var in
      List.iter (mark_self_dirty lane) watchers)

  let refresh_timer_source_for_compute lane staging signal =
    Graph.with_timer_refresh_timer graph lane signal.timer
      ~none:(fun () -> ())
      ~some:(fun timer_refresh timer ->
        graph_result_or_raise
          (Timer.refresh_node_on_demand
             ~runtime_mismatch:timer_runtime_mismatch
             ~current_snapshot:timer_current_snapshot
             ~effective_state:timer_effective_state
             ~remember:(remember_timer_refresh_timer lane staging)
             ~run_operation:(fun timer ~now_ms operation ->
               stage_timer_refresh_operation lane staging timer now_ms operation)
             timer_refresh timer))

  let notify_signal_changed lane staging signal =
    List.iter (fun notify -> notify ()) signal.dirty_listeners;
    List.iter
      (fun (O observer) -> mark_observer_candidate observer)
      signal.signal_observers;
    Topology.iter signal.dependents (fun edge ->
        Scheduler.note_propagation_edge_visit scheduler_counters;
        mark_timer_refresh_dirty lane staging edge.parent)

  let rec compute : type a. graph_lane -> Graph.staging -> a signal -> a * bool
      =
   fun lane staging signal ->
    if not (signal_valid signal) then raise (Graph_error `Invalid_scope);
    refresh_timer_source_for_compute lane staging signal;
    let generation = current_generation lane in
    let already_computed = signal.computed_generation = generation in
    let ((_, changed) as result) =
      Graph.compute_cached graph lane compute_ops (P signal)
        ~current:(fun _compute_node -> effective_signal_value signal)
        ~cycle:(fun _compute_node -> raise (Graph_error `Cycle))
        ~compute:(fun _compute_node -> compute_uncached lane staging signal)
    in
    if changed && not already_computed then
      notify_signal_changed lane staging signal;
    result

  and compute_uncached :
      type a. graph_lane -> Graph.staging -> a signal -> a * bool =
   fun lane staging signal ->
    remember_computed lane staging (P signal);
    let signal_initialized () =
      Signal_snapshot.is_initialized (signal_effective_snapshot signal)
    in
    let recompute value =
      Graph.bump_counter graph lane Graph.Recompute_count;
      Scheduler.note_cutoff_call scheduler_counters;
      let snapshot = signal_effective_snapshot signal in
      let changed =
        Graph_algorithms.Value_cutoff.changed ~equal:signal.equal
          ~initialized:(Signal_snapshot.is_initialized snapshot)
          ~current:(Signal_snapshot.value snapshot) ~next:value
      in
      if changed then stage_signal lane staging signal value;
      (if changed then value else current_or_raise signal), changed
    in
    let use_cached () = (current_or_raise signal, false) in
    let dependency_changed dependencies =
      dependencies_changed lane signal dependencies
    in
    let recompute_with_dependencies dependencies value =
      stage_dependency_versions lane staging signal dependencies;
      recompute value
    in
    let static_child child_signal =
      Graph_algorithms.Static_eval.child ~dependency:(P child_signal)
        (compute lane staging child_signal)
    in
    let finish_static ?(stage_dependencies = true) result =
      Graph_algorithms.Static_eval.plan ~stage_dependencies ~dirty:signal.dirty
        ~initialized:(signal_initialized ())
        ~dependencies_changed:dependency_changed result
      |> Graph_algorithms.Static_eval.plan_result ~use_cached
           ~recompute:(fun ~dependencies ~output ~stage_dependencies ->
             if stage_dependencies then
               recompute_with_dependencies dependencies output
             else recompute output)
    in
    match signal.kind with
    | Const value ->
        finish_static ~stage_dependencies:false (Graph_algorithms.Static_eval.leaf value)
    | Var var ->
        finish_static ~stage_dependencies:false
          (Graph_algorithms.Static_eval.leaf (effective_var_value var))
    | Map (a, f) ->
        let a_child = static_child a in
        finish_static (Graph_algorithms.Static_eval.map a_child f)
    | Map2 (a, b, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        finish_static
          (Graph_algorithms.Static_eval.map2 a_child b_child f)
    | Map3 (a, b, c, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        finish_static
          (Graph_algorithms.Static_eval.map3 a_child b_child c_child f)
    | Map4 (a, b, c, d, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        finish_static
          (Graph_algorithms.Static_eval.map4 a_child b_child c_child d_child f)
    | Map5 (a, b, c, d, e, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        finish_static
          (Graph_algorithms.Static_eval.map5 a_child b_child c_child d_child e_child f)
    | Map6 (a, b, c, d, e, f_signal, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        finish_static
          (Graph_algorithms.Static_eval.map6 a_child b_child c_child d_child e_child
             f_child f)
    | Map7 (a, b, c, d, e, f_signal, g, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        let g_child = static_child g in
        finish_static
          (Graph_algorithms.Static_eval.map7 a_child b_child c_child d_child e_child
             f_child g_child f)
    | Map8 (a, b, c, d, e, f_signal, g, h, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        let g_child = static_child g in
        let h_child = static_child h in
        finish_static
          (Graph_algorithms.Static_eval.map8 a_child b_child c_child d_child e_child
             f_child g_child h_child f)
    | Map9 (a, b, c, d, e, f_signal, g, h, i, f) ->
        let a_child = static_child a in
        let b_child = static_child b in
        let c_child = static_child c in
        let d_child = static_child d in
        let e_child = static_child e in
        let f_child = static_child f_signal in
        let g_child = static_child g in
        let h_child = static_child h in
        let i_child = static_child i in
        finish_static
          (Graph_algorithms.Static_eval.map9 a_child b_child c_child d_child e_child
             f_child g_child h_child i_child f)
    | All signals ->
        let children =
          List.fold_right
            (fun child_signal children ->
              static_child child_signal :: children)
            signals []
        in
        finish_static (Graph_algorithms.Static_eval.all children)
    | Bind bind ->
        compute_bind_dynamic lane staging signal bind
    | Keyed keyed ->
        compute_keyed lane staging signal keyed

  and compute_keyed :
      type key data output data_map output_map child_map.
      graph_lane ->
      Graph.staging ->
      output_map signal ->
      (key, data, output, data_map, output_map, child_map) keyed ->
      output_map * bool =
   fun lane staging signal keyed ->
    bump_keyed_counter Reconciliation_count;
    let child_ops = keyed.keyed_child_ops in
    let output_ops = keyed.keyed_output_ops in
    let input, _input_changed = compute lane staging keyed.keyed_input in
    let current_input = Transaction.current keyed.keyed_raw_input in
    let current_children = Transaction.current keyed.keyed_children in
    let current_output =
      match Signal_snapshot.value (signal_effective_snapshot signal) with
      | Some output -> output
      | None -> output_ops.keyed_output_empty
    in
    let plan =
      {
        keyed_plan_input = input;
        keyed_plan_children = current_children;
        keyed_plan_output = current_output;
        keyed_plan_removals = [];
        keyed_plan_additions = [];
        keyed_plan_updates = [];
        keyed_plan_provisional_scopes = [];
        keyed_plan_processed = child_ops.keyed_empty;
      }
    in
    keyed.keyed_pending <- Some plan;
    Hashtbl.replace pending_keyed signal.id (Packed_keyed (signal, keyed));
    let visited = ref child_ops.keyed_empty in
    let find_child key =
      match child_ops.keyed_find_opt key current_children with
      | Some child -> child
      | None -> raise (Graph_error `Invalid_scope)
    in
    let compute_child child =
      bump_keyed_counter Child_visit_count;
      let value, changed = compute lane staging child.keyed_child_output in
      if changed then
        plan.keyed_plan_output <-
          output_ops.keyed_output_set child.keyed_child_key value
            plan.keyed_plan_output;
      visited :=
        child_ops.keyed_set child.keyed_child_key child !visited
    in
    let add_child key candidate =
      let scope = new_scope signal in
      plan.keyed_plan_provisional_scopes <-
        scope :: plan.keyed_plan_provisional_scopes;
      bump_keyed_counter Provisional_addition_count;
      let source, data_signal, output_signal =
        Graph.with_current_scope graph scope_ops scope (fun () ->
            let source = new_var candidate in
            let data_signal = watch_var source in
            let output_signal =
              keyed.keyed_builder ~key ~data:data_signal
            in
            (source, data_signal, output_signal))
      in
      (match Scope_validation.validate_inner ~scope (P output_signal) with
      | Ok () -> ()
      | Error `Invalid_scope -> raise (Graph_error `Invalid_scope));
      let rec child =
        {
          keyed_child_key = key;
          keyed_child_scope = scope;
          keyed_child_source = source;
          keyed_child_data = data_signal;
          keyed_child_output = output_signal;
          keyed_child_listener =
            (fun () ->
              keyed.keyed_affected <-
                child_ops.keyed_set key child keyed.keyed_affected);
        }
      in
      plan.keyed_plan_additions <- child :: plan.keyed_plan_additions;
      plan.keyed_plan_children <-
        child_ops.keyed_set key child plan.keyed_plan_children;
      compute_child child
    in
    let update_child key candidate =
      let child = find_child key in
      let published = Transaction.current child.keyed_child_source.source_value in
      if
        not
          (cutoff_equal keyed.keyed_data_cutoff published candidate)
      then (
        plan.keyed_plan_updates <- child :: plan.keyed_plan_updates;
        Graph.stage_cell graph lane staging
          child.keyed_child_source.source_value candidate;
        Graph.stage_cell graph lane staging
          child.keyed_child_source.graph_value candidate;
        mark_self_dirty lane (P child.keyed_child_data);
        let reset_compute_memo signal =
          if signal.seen_generation = current_generation lane then (
            signal.seen_generation <- -1;
            signal.changed_seen <- false)
        in
        reset_compute_memo child.keyed_child_data;
        reset_compute_memo child.keyed_child_output;
        compute_child child)
    in
    let remove_child key =
      let child = find_child key in
      plan.keyed_plan_removals <- child :: plan.keyed_plan_removals;
      plan.keyed_plan_children <-
        child_ops.keyed_remove key plan.keyed_plan_children;
      plan.keyed_plan_output <-
        output_ops.keyed_output_remove child.keyed_child_key plan.keyed_plan_output
    in
    keyed.keyed_data_ops.keyed_fold_symmetric_diff current_input input
      ~on_compare:(fun () -> bump_keyed_counter Input_key_comparison_count)
      ~init:()
      ~f:(fun () key -> function
        | change ->
            bump_keyed_counter Input_diff_event_count;
            match change with
            | Keyed_left _ -> remove_child key
            | Keyed_right candidate -> add_child key candidate
            | Keyed_changed (_, candidate) -> update_child key candidate);
    plan.keyed_plan_processed <- keyed.keyed_affected;
    child_ops.keyed_fold
      (fun key affected () ->
        match child_ops.keyed_find_opt key plan.keyed_plan_children with
        | Some child
          when child == affected
               && Option.is_none (child_ops.keyed_find_opt key !visited) ->
            compute_child child
        | Some _ | None -> ())
      keyed.keyed_affected ();
    Graph.stage_cell graph lane staging keyed.keyed_raw_input input;
    Graph.stage_cell graph lane staging keyed.keyed_children
      plan.keyed_plan_children;
    Graph.bump_counter graph lane Graph.Recompute_count;
    let snapshot = signal_effective_snapshot signal in
    let changed =
      Graph_algorithms.Value_cutoff.changed ~equal:signal.equal
        ~initialized:(Signal_snapshot.is_initialized snapshot)
        ~current:(Signal_snapshot.value snapshot)
        ~next:plan.keyed_plan_output
    in
    if changed then stage_signal lane staging signal plan.keyed_plan_output;
    ((if changed then plan.keyed_plan_output else current_or_raise signal), changed)

  and compute_bind_dynamic :
      type source value.
      graph_lane ->
      Graph.staging ->
      value signal ->
      (source, value) bind ->
      value * bool =
   fun lane staging signal bind ->
    let switch =
      Bind.dynamic_switch_plan
        ~new_scope:(fun _lane -> new_scope signal)
        ~with_scope:(fun _lane scope f ->
          Graph.with_current_scope graph scope_ops scope f)
        ~on_switch_failure:(fun lane scope ->
          remember_pure_disposal_hooks lane staging
            (invalidate_scope lane scope))
        ~selector:bind.selector
        ~validate_inner:(fun _lane scope inner ->
          Scope_validation.validate_inner ~scope (P inner))
        ~compute_inner:(fun lane inner -> compute lane staging inner)
    in
    let reuse =
      Bind.dynamic_reuse_plan ~dirty:signal.dirty
        ~dependencies_changed:(fun lane dependencies ->
          dependencies_changed lane signal dependencies)
    in
    let source =
      Bind.dynamic_source_plan ~equal:bind.source.equal
        ~compute_source:(fun lane -> compute lane staging bind.source)
        ~source_dependency:(P bind.source)
        ~inner_dependency:(fun inner -> P inner)
    in
    let value =
      Bind.dynamic_value_context
        ~state:(fun () ->
          let snapshot = signal_effective_snapshot signal in
          Bind.dynamic_value_state
            ~initialized:(Signal_snapshot.is_initialized snapshot)
            ~current:(Signal_snapshot.value snapshot))
        ~cached_value:(fun () -> current_or_raise signal)
        ~value_equal:signal.equal
        ~bump_recompute:(fun () ->
          Graph.bump_counter graph lane Graph.Recompute_count)
    in
    let staging_context =
      Bind.dynamic_staging_context
        ~stage_switch:(fun ~source_value ~inner ~scope ->
          stage_bind_switch lane staging bind source_value inner scope)
        ~stage_dependencies:(stage_dependency_versions lane staging signal)
        ~stage_value:(stage_signal lane staging signal)
    in
    let context =
      Bind.dynamic_context ~source ~switch ~reuse ~value
        ~staging:staging_context
    in
    match
      Bind.run_dynamic context lane (bind_effective_snapshot bind)
    with
    | Error `Invalid_scope -> raise (Graph_error `Invalid_scope)
    | Ok result -> result

  let settle_scheduler lane staging =
    let generation = current_generation lane in
    let invalidations = collect_staged_bind_invalidations lane staging in
    let visit_state (P signal) =
      if signal.schedule_visit_generation = generation then
        signal.schedule_visit_state
      else Scheduler_unseen
    in
    let set_visit_state (P signal) state =
      signal.schedule_visit_generation <- generation;
      signal.schedule_visit_state <- state
    in
    let computable (P signal) =
      signal_valid signal
      && signal.demand > 0
      && signal.computed_generation <> generation
      && not (staged_bind_invalidates invalidations (P signal))
    in
    let dirty_dependency (P signal) = computable (P signal) && signal.dirty in
    let settle_claimed packed =
      match visit_state packed with
      | Scheduler_done -> ()
      | Scheduler_visiting -> raise (Graph_error `Cycle)
      | Scheduler_unseen ->
          set_visit_state packed Scheduler_visiting;
          let stack = ref [ { frame_node = packed; frame_next_dependency = 0 } ] in
          while !stack <> [] do
            match !stack with
            | [] -> ()
            | frame :: rest ->
                let (P signal) = frame.frame_node in
                let dependency_count =
                  match signal.kind with
                  | Keyed _ -> 0
                  | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _
                  | Map5 _ | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _
                  | Bind _ ->
                      Topology.length signal.dependencies
                in
                if not (computable frame.frame_node) then (
                  stack := rest;
                  set_visit_state frame.frame_node Scheduler_done)
                else if frame.frame_next_dependency < dependency_count then (
                  let edge =
                    Topology.get signal.dependencies frame.frame_next_dependency
                  in
                  Scheduler.note_dependency_edge_visit scheduler_counters;
                  frame.frame_next_dependency <- frame.frame_next_dependency + 1;
                  let child = edge.child in
                  if dirty_dependency child then
                    match visit_state child with
                    | Scheduler_done -> ()
                    | Scheduler_visiting -> raise (Graph_error `Cycle)
                    | Scheduler_unseen ->
                        set_visit_state child Scheduler_visiting;
                        stack :=
                          { frame_node = child; frame_next_dependency = 0 }
                          :: !stack)
                else (
                  stack := rest;
                  if computable frame.frame_node then (
                    Scheduler.note_node_evaluation scheduler_counters;
                    ignore (compute lane staging signal : _ * bool));
                  set_visit_state frame.frame_node Scheduler_done)
          done
    in
    let rec loop () =
      match Scheduler.claim scheduler scheduler_access with
      | None -> ()
      | Some packed ->
          if computable packed then settle_claimed packed;
          loop ()
    in
    loop ()

  let update_necessity_counters_unlocked _lane = ()

  let set_pending_cleanup_hooks hooks_ref hooks =
    if Cleanup.pending hooks_ref then
      invalid_arg "Eta_signal: pending cleanup hooks overwritten";
    hooks_ref := hooks;
    match hooks with
    | [] -> ()
    | _ :: _ -> Work.admit work Work.Cleanup

  let release_pending_cleanup_work pending =
    if pending then Effect.sync (fun () -> Work.release work Work.Cleanup)
    else Effect.unit

  let run_pending_cleanup_as_finalizers hooks_ref =
    let pending = Cleanup.pending hooks_ref in
    Cleanup.run_pending_as_finalizers hooks_ref
    |> Effect.on_exit (fun _ -> release_pending_cleanup_work pending)

  let fail_with_pending_disposal_hooks hooks_ref eff =
    let pending = Cleanup.pending hooks_ref in
    Cleanup.fail_with_pending hooks_ref eff
    |> Effect.on_exit (fun _ -> release_pending_cleanup_work pending)

  let graph_error_with_pending_disposal_hooks hooks_ref err =
    fail_with_pending_disposal_hooks hooks_ref
      (Effect.fail (err :> stabilize_error))

  let timer_drain_snapshot = ref []

  (* Reconciliation resources are the union of queued transition timers
     (drained on success) and currently necessary timers (runtime-contract
     validation on every refresh, even without a pending transition). The
     necessary set is the incrementally maintained registry, not a scan. *)
  let timer_demand_plan_unlocked _lane =
    let queued_ids = Hashtbl.create 8 in
    let rec collect (P signal as packed) (drained, timers) =
      let drained, timers =
        match signal.timer with
        | Some timer when Hashtbl.mem timer_nodes signal.id ->
            Hashtbl.replace queued_ids (signal_id_int signal.id) ();
            ( (signal.id, signal.timer_reconcile_token) :: drained,
              (signal.id, timer) :: timers )
        | Some _ | None -> (drained, timers)
      in
      match timer_reconcile_next packed with
      | None -> (drained, timers)
      | Some next -> collect next (drained, timers)
    in
    let drained, timers =
      match timer_reconcile_pending () with
      | None -> ([], [])
      | Some head -> collect head ([], [])
    in
    let timers =
      Hashtbl.fold
        (fun _ (P signal) timers ->
          match signal.timer with
          | Some timer
            when signal.demand > 0
                 && not (Hashtbl.mem queued_ids (signal_id_int signal.id)) ->
              (signal.id, timer) :: timers
          | Some _ -> timers
          | None -> assert false)
        timer_nodes timers
    in
    timer_drain_snapshot := drained;
    Timer.node_demand_plan ~timers
      ~is_necessary:(fun id ->
        match Hashtbl.find_opt timer_nodes id with
        | Some (P signal) -> signal.demand > 0
        | None -> false)
      ~runtime_mismatch:timer_runtime_mismatch
      ~state:timer_state_port

  let current_runtime_contract () =
    Spi.Expert.make ~leaf_name:"Eta_signal.current_runtime_contract"
      (fun context -> Eta.Exit.Ok (Spi.Expert.contract context))

  let timer_demand_access =
    Timer.demand_effect_access
      ~with_access:
        { run_access =
          (fun f ->
            with_graph_lane_access (fun lane ->
                try f lane with Graph_error err -> Error err)
            |> Effect.flatten_result)
        }

  let unlink_drained_timer_reconciliations () =
    match !timer_drain_snapshot with
    | [] -> Effect.unit
    | drained ->
        timer_drain_snapshot := [];
        with_graph_lane_access (fun _lane ->
            List.iter
              (fun (id, token) ->
                match Hashtbl.find_opt timer_nodes id with
                | Some packed -> unlink_timer_reconcile_token packed token
                | None -> ())
              drained)

  let refresh_timer_demand () =
    Timer.node_demand_refresh
      ~advance_generation:(checked_succ "timer generation")
      ~access:timer_demand_access
      ~demand:
        (Timer.node_demand_effect_port ~plan:(fun _runtime_contract lane ->
             timer_demand_plan_unlocked lane))
    |> Timer.run_node_demand_refresh
    |> Effect.bind unlink_drained_timer_reconciliations

  let timer_demand_cleanup_pending = ref false

  let mark_timer_demand_cleanup_pending_unlocked () =
    if not !timer_demand_cleanup_pending then (
      timer_demand_cleanup_pending := true;
      Work.admit work Work.Timer_reconciliation)

  let claim_timer_demand_cleanup () =
    with_graph_lane_access (fun _lane ->
        if !timer_demand_cleanup_pending then (
          timer_demand_cleanup_pending := false;
          Work.release work Work.Timer_reconciliation;
          true)
        else false)

  let restore_timer_demand_cleanup () =
    with_graph_lane_access (fun _lane ->
        if not !timer_demand_cleanup_pending then (
          timer_demand_cleanup_pending := true;
          Work.admit work Work.Timer_reconciliation))

  let run_pending_timer_demand_cleanup () =
    claim_timer_demand_cleanup ()
    |> Effect.bind (function
         | false -> Effect.unit
         | true ->
             refresh_timer_demand ()
             |> Effect.on_exit (function
                  | Eta.Exit.Ok () -> Effect.unit
                  | Eta.Exit.Error _ -> restore_timer_demand_cleanup ()))

  let defect_with_pending_disposal_hooks hooks_ref exn backtrace =
    fail_with_pending_disposal_hooks hooks_ref
      (Effect.sync (fun () -> Printexc.raise_with_backtrace exn backtrace))

  let run_pending_stabilize_cleanup hooks_ref refresh_timers =
    if !refresh_timers then
      (Effect.sync (fun () -> refresh_timers := false)
       |> Effect.bind (fun () ->
              refresh_timer_demand ()
              |> Effect.map_error (fun err -> (err :> stabilize_error))
              |> Effect.bind (fun () ->
                     run_pending_cleanup_as_finalizers hooks_ref)))
      |> Effect.uninterruptible
    else run_pending_cleanup_as_finalizers hooks_ref

  let run_pending_dispose_cleanup hooks_ref =
    (run_pending_timer_demand_cleanup ()
    |> Effect.on_exit (fun _exit ->
           run_pending_cleanup_as_finalizers hooks_ref))
    |> Effect.uninterruptible

  let run_pending_registration_abort_cleanup hooks_ref refresh_timers =
    if !refresh_timers || Cleanup.pending hooks_ref then
      ((if !refresh_timers then
          Effect.sync (fun () -> refresh_timers := false)
          |> Effect.bind (fun () -> refresh_timer_demand ())
        else Effect.unit)
       |> Effect.on_exit (fun _exit ->
              run_pending_cleanup_as_finalizers hooks_ref))
      |> Effect.uninterruptible
    else Effect.unit

  let dispose_observer_with_cleanup cleanup observer =
    let hooks_ref = ref [] in
    let lane_entered = ref false in
    let cleanup_started = ref false in
    let run_cleanup () =
      cleanup_started := true;
      cleanup hooks_ref
    in
    with_graph_lane_access
      (fun lane ->
        lane_entered := true;
        (match observer.obs_state with
         | Observer_lifecycle.Disposed _ -> ()
         | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
         | Observer_lifecycle.Invalid_scope _ ->
          let hooks = dispose_observer_unlocked lane observer in
          set_pending_cleanup_hooks hooks_ref hooks;
          mark_timer_demand_cleanup_pending_unlocked ();
          update_necessity_counters_unlocked lane))
    |> Effect.bind (fun () -> run_cleanup ())
    |> Effect.on_exit (fun _exit ->
           if !cleanup_started || not !lane_entered then Effect.unit
           else run_cleanup ())

  let dispose_observer_effect observer =
    dispose_observer_with_cleanup run_pending_dispose_cleanup observer

  let abort_observer_registration_effect observer =
    let hooks_ref = ref [] in
    let refresh_timers = ref false in
    let cleanup_started = ref false in
    let cleanup_needed = ref false in
    let run_cleanup () =
      cleanup_started := true;
      run_pending_registration_abort_cleanup hooks_ref refresh_timers
    in
    with_graph_lane_access
      (fun lane ->
        match observer.obs_state with
        | Observer_lifecycle.Registering _ | Observer_lifecycle.Active _
        | Observer_lifecycle.Invalid_scope _ ->
            let hooks = dispose_observer_unlocked lane observer in
            set_pending_cleanup_hooks hooks_ref hooks;
            refresh_timers := true;
            update_necessity_counters_unlocked lane;
            cleanup_needed := true;
            true
        | Observer_lifecycle.Disposed _ -> false)
    |> Effect.bind (function
         | true -> run_cleanup ()
         | false -> Effect.unit)
    |> Effect.on_exit (fun _exit ->
           if !cleanup_started || not !cleanup_needed then Effect.unit
           else run_cleanup ())

  let cleanup_observer_registration_on_error cleanup eff =
    let render_graph_error err =
      Format.asprintf "%a" Error.pp_graph_error err
    in
    Spi.Expert.make @@ fun context ->
    let exit =
      try Spi.Expert.eval context eff
      with exn -> Spi.Expert.exit_of_exn context exn
    in
    match exit with
    | Eta.Exit.Ok _ -> exit
    | Eta.Exit.Error primary -> (
        let cleanup_exit =
          try Spi.Expert.eval context (cleanup ())
          with exn -> Spi.Expert.exit_of_exn context exn
        in
        match cleanup_exit with
        | Eta.Exit.Ok () -> Eta.Exit.Error primary
        | Eta.Exit.Error cleanup_cause ->
            Eta.Exit.Error
              (Eta.Cause.suppressed ~primary
                 ~finalizer:
                   (Eta.Cause.finalizer_of_cause
                      (fun fmt error ->
                        Format.pp_print_string fmt (render_graph_error error))
                      cleanup_cause)))

  let compare_signal_scope_then_id (P left) (P right) =
    match Int.compare (Scope.depth left.scope) (Scope.depth right.scope) with
    | 0 -> Int.compare (signal_id_int left.id) (signal_id_int right.id)
    | order -> order

  let observer_order_dependencies : type a. a signal -> packed_signal list =
   fun signal ->
    match signal.kind with
    | Bind bind ->
        Bind.dependencies ~source:(P bind.source)
          ~inner_dependency:(fun inner -> P inner)
          (bind_effective_snapshot bind)
    | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _
    | Map7 _ | Map8 _ | Map9 _ | All _ | Keyed _ ->
        signal_dependencies signal

  let observer_plan_access =
    Observer_plan.access
      ~node_id:(fun (P signal) -> signal_id_int signal.id)
      ~dependencies:(fun (P signal) -> observer_order_dependencies signal)
      ~observer_id:(fun (O observer) -> observer_id_int observer.obs_id)
      ~observed:(fun (O observer) -> P observer.obs_signal)

  let plan_observer_delivery_order observers =
    match observers with
    | [] -> []
    | [ observer ] when not (Observer_plan.counters_enabled observer_plan_counters)
      ->
        [ observer ]
    | _ ->
        Observer_plan.plan observer_plan_counters observer_plan_access
          ~cycle:(fun () -> raise (Graph_error `Cycle))
          observers

  let collect_observed_bind_nodes _lane _observers =
    Hashtbl.fold
      (fun _ packed binds -> packed :: binds)
      necessary_bind_nodes []
    |> List.sort compare_signal_scope_then_id

  let plan_staged_bind_switches lane staging observers =
    if Hashtbl.length necessary_bind_nodes > 0 then (
      let invalidations = ref (collect_staged_bind_invalidations lane staging) in
      let planned_bind_ids = Hashtbl.create 8 in
      let refresh_invalidations () =
        invalidations := collect_staged_bind_invalidations lane staging
      in
      let plan_bind_if_needed (P signal as packed) =
        let signal_id = signal_id_int signal.id in
        if
          signal_valid signal
          && (not (Hashtbl.mem planned_bind_ids signal_id))
          && not (staged_bind_invalidates !invalidations packed)
        then (
          Hashtbl.replace planned_bind_ids signal_id ();
          match signal.kind with
          | Bind _ ->
              ignore (compute lane staging signal : _ * bool);
              refresh_invalidations ();
              true
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Keyed _ ->
              false)
        else false
      in
      let rec loop () =
        let planned_any =
          List.fold_left
            (fun planned packed -> plan_bind_if_needed packed || planned)
            false
            (collect_observed_bind_nodes lane observers)
        in
        if planned_any then loop ()
      in
      loop ())

  let graph_error_of_die die =
    match die.Eta.Cause.exn with
    | Graph_error err -> Some err
    | _ -> None

  let run_observer_effect _observer _token observer_eff =
    Spi.Expert.make ~leaf_name:"eta_signal.observer" @@ fun context ->
    try
      match Spi.Expert.eval context observer_eff with
      | Eta.Exit.Ok () -> Eta.Exit.Ok ()
      | Eta.Exit.Error cause ->
          Eta.Exit.Error
            (Error.observer_cause_to_stabilize ~graph_error_of_die cause)
    with
    | Graph_error err ->
        Eta.Exit.Error (Eta.Cause.Fail (err :> stabilize_error))

  let event_observer_active (_lane : graph_lane) observer =
    Observer_delivery_counters.note_lifecycle_check observer_delivery_counters;
    let active = observer_active (O observer) in
    if not active then
      Observer_delivery_counters.note_terminal_skip observer_delivery_counters;
    active

  let construct_observer_effect (_lane : graph_lane) observer token update =
    try Ok (Some (observer.obs_callback token update))
    with Graph_error err -> Error (err :> stabilize_error)

  let observer_delivery_event_port () =
    let activation =
      Observer_core.delivery_event_activation_plan
        ~active:event_observer_active
    in
    let callback =
      Observer_core.delivery_event_callback_plan
        ~construct:construct_observer_effect
        ~run_callback:(fun observer token observer_eff ->
          Observer_delivery_counters.note_callback_attempt
            observer_delivery_counters;
          run_observer_effect observer token observer_eff)
    in
    Observer_core.delivery_event_port ~activation ~callback

  let observer_delivery_event_access =
    Observer_core.delivery_event_access
      ~with_delivery_access:
        { run_delivery =
          (fun f -> with_graph_lane_access (fun lane -> f lane))
        }

  let observer_update_collection_port staging invalidations =
    Observer_core.update_collection_port
      ~live:(fun (_lane : graph_lane) observer ->
        observer_active_live_state observer)
      ~skip:(fun (_lane : graph_lane) observer ->
        staged_bind_invalidates invalidations (P observer.obs_signal))
      ~compute:(fun lane observer -> compute lane staging observer.obs_signal)
      ~snapshot:(fun (_lane : graph_lane) live ->
        observer_effective_snapshot live)
      ~stage_snapshot:(fun lane live snapshot ->
        Graph.stage_cell graph lane staging live.observer_snapshot snapshot)
      ~equal:(fun observer -> observer.obs_equal)

  let collect_typed_observer_event staging lane (type a)
      (observer : a observer) =
    let invalidations = collect_staged_bind_invalidations lane staging in
    let context =
      Observer_core.delivery_event_context
        ~access:observer_delivery_event_access
        ~delivery:(observer_delivery_port ())
        ~event:(observer_delivery_event_port ())
        ~token:current_generation
    in
    let source =
      Observer_core.delivery_event_source context
        (observer_update_collection_port staging invalidations)
    in
    let event = Observer_core.collect_delivery_event source lane observer in
    event

  let observer_delivery_event_source staging =
    let collected_observers = ref [] in
    Observer_core.delivery_event_source_of_collect_event
      ~collect_event:(fun lane (O observer as packed) ->
        let event = collect_typed_observer_event staging lane observer in
        collected_observers := packed :: !collected_observers;
        event)
      ~finish_collection:(fun _lane ->
        List.iter
          (fun (O observer) -> finish_observer_candidate observer)
          !collected_observers;
        collected_observers := [])

  let run_events events =
    Observer_core.Delivery_event.run
      ~after_claim:(fun () -> Effect.unit)
      events

  let begin_stabilize lane timer_refresh =
    Option.iter
      (fun _ ->
        Hashtbl.iter
          (fun _id (P signal as packed) ->
            if signal.demand > 0 then schedule_signal packed)
          timer_nodes)
      timer_refresh;
    let pending =
      Graph.stabilization_pending_plan
        ~release_marks:(fun (_lane : graph_lane) pending ->
          Graph.stabilization_pending_mark_release ~release:(fun () ->
              Scheduler.begin_attempt scheduler;
              List.iter
                (fun (V var) ->
                  var.queued <- false;
                  Work.release work Work.Sources)
                pending))
        ~stage:(fun lane staging pending ->
          Graph.stabilization_pending_stage ~stage:(fun () ->
              List.iter (stage_pending_var lane staging) pending))
    in
    let observers =
      Graph.stabilization_observer_plan
        ~candidates:(fun _lane -> observer_candidates ())
        ~delivery:(fun lane staging ->
          let selection =
            Observer_core.delivery_selection_plan
              ~active:(fun observer ->
                observer_active observer
                && observer_delivery_candidate observer)
              ~plan:plan_observer_delivery_order
          in
          Observer_core.delivery_event_collection ~selection
            (observer_delivery_event_source staging))
        ~plan_staged_binds:(fun lane staging observers ->
          Graph.staged_bind_planning ~plan:(fun () ->
              plan_staged_bind_switches lane staging observers;
              settle_scheduler lane staging))
    in
    let commit =
      Graph.stabilization_commit_plan
        ~staging:staging_commit_plan
        ~update_necessity:(fun lane ->
          Graph.stabilization_necessity_update ~update:(fun () ->
              update_necessity_counters_unlocked lane))
    in
    let pure =
      Graph.stabilization_pure_ops ~pending ~observers ~commit
    in
    let rollback =
      Graph.stabilization_rollback_ops
        ~staging:staging_reset_context
        ~mark_observers_failed_without_current:
          (fun lane observers ->
            Graph.stabilization_observer_failure_mark ~mark:(fun () ->
                List.iter (mark_failed_without_current lane) observers))
        ~requeue_pending:(fun lane pending ->
          Graph.stabilization_pending_requeue ~requeue:(fun () ->
              List.iter (requeue_if_needed lane) pending))
    in
    Graph.run_stabilization graph lane ~timer_refresh
      (Graph.stabilization_ops
         ~classify_graph_error:(function
           | Graph_error err -> Some err
           | _ -> None)
         ~pure ~rollback)

  let begin_stabilize_with_pending_hooks lane timer_refresh hooks_ref
      stabilization_finish =
    let result = begin_stabilize lane timer_refresh in
    let hooks =
      Graph.record_stabilization_result stabilization_finish lane result
    in
    set_pending_cleanup_hooks hooks_ref hooks;
    result

  let stabilization_delivery_ops hooks_ref refresh_timers stabilization_finish =
    Graph.stabilization_delivery_ops graph stabilization_finish
      (Graph.stabilization_delivery_context
         ~run_pending_cleanup:(fun () ->
           run_pending_stabilize_cleanup hooks_ref refresh_timers)
         ~run_events
         ~with_lane_access:(fun f -> with_graph_lane_access f))

  let stabilize =
    Effect.sync (fun () ->
        (ref [], ref false, Graph.create_stabilization_finish ()))
    |> Effect.bind
         (fun (hooks_ref, refresh_timers, stabilization_finish) ->
           let delivery_ops =
             stabilization_delivery_ops hooks_ref refresh_timers
               stabilization_finish
           in
           (current_runtime_contract ()
            |> Effect.bind (fun runtime_contract ->
                   let stabilization_result =
                     with_graph_lane_access (fun lane ->
                         try
                           if
                             Graph.stabilization_idle graph
                             && Work.check_quiescent work
                           then None
                           else
                             let timer_refresh =
                               Some
                                 (Timer_policy.create_refresh_context
                                    ~token:(next_timer_refresh_token_unlocked lane)
                                    ~runtime_contract
                                    ~now_ms:runtime_contract.Runtime_contract.now_ms)
                             in
                             Some
                               (begin_stabilize_with_pending_hooks lane
                                  timer_refresh hooks_ref stabilization_finish)
                         with Graph_error err ->
                           Some (Atomic_pass.graph_error ~hooks:[] err))
                   in
                   stabilization_result
                   |> Effect.bind (function
                        | None -> Effect.unit
                        | Some result ->
                            Atomic_pass.result result
                              ~graph_error:(fun ~hooks:_ err ->
                                graph_error_with_pending_disposal_hooks hooks_ref
                                  err)
                              ~defect:(fun ~hooks:_ exn backtrace ->
                                defect_with_pending_disposal_hooks hooks_ref exn
                                  backtrace)
                              ~planning_ok:
                                (fun ~hooks:_ ~events ->
                                  refresh_timers := true;
                                  Atomic_pass.deliver delivery_ops events))))
           |> Effect.on_exit (fun _exit ->
                  Atomic_pass.finish_delivery delivery_ops))

  module Var = struct
    type 'a t = 'a var

    let create ?(cutoff = Cutoff.phys_equal) value =
      new_var ~equal:(cutoff_equal cutoff) value

    let value (source : 'a t) =
      ensure_graph_context ();
      ignore (graph_result_or_raise (Graph.ensure_not_pure graph));
      Transaction.current source.source_value

    let watch (source : 'a t) = watch_var source

    let queue_var lane (source : 'a t) = queue_var_unlocked lane source

    let set_unlocked lane (source : 'a t) value =
      set_var_source_unlocked lane source value

    let set (source : 'a t) value =
      with_graph_lane_access (fun lane ->
          if source.updating then Error `Reentrant_update
          else (
            set_unlocked lane source value;
            Ok ()))
      |> Effect.flatten_result

    let set_from_update (source : 'a t) value =
      with_graph_lane_access (fun lane ->
          set_unlocked lane source value;
          value)

    let release_update (source : 'a t) =
      with_graph_lane_sync (fun () -> source.updating <- false)

    let update_effect (source : 'a t) f =
      let acquired = ref false in
      let acquire =
        with_graph_lane_sync (fun () ->
            if source.updating then Error `Reentrant_update
            else (
              source.updating <- true;
              acquired := true;
              Ok (Transaction.current source.source_value)))
        |> Effect.flatten_result
      in
      let release_if_acquired () =
        if !acquired then release_update source else Effect.unit
      in
      (acquire
       |> Effect.bind (fun old_value ->
              Effect.sync (fun () -> f old_value)
              |> Effect.bind (fun update_eff -> update_eff)
              |> Effect.bind (fun new_value ->
                     set_from_update source new_value)))
      |> Effect.on_exit (fun _ -> release_if_acquired ())
  end

  module Observer = struct
    type 'a t = 'a observer
    type observer_finish = [ `Disposed | `Invalid_scope ]
    type delivery_token = Observer_core.Delivery.token

    let finish_of_lifecycle = function
      | Observer_lifecycle.Finish_disposed -> `Disposed
      | Observer_lifecycle.Finish_invalid_scope -> `Invalid_scope

    type 'a delivery =
      (delivery_token, 'a update, observer_after_ack_action)
      Observer_core.Delivery_handle.t

    let delivery observer token update =
      Observer_core.make_delivery_handle
        ~access:observer_delivery_event_access
        (observer_delivery_port ()) ~observer ~token update

    let transfer_active_observer observer =
      (* This is deliberately a same-domain leaf, not another lane acquisition:
         the transfer check must not introduce a new lane-release callback
         window between the final state check and returning the handle. *)
      Effect.sync (fun () ->
          ensure_graph_context ();
          Observer_core.activate_observer (observer_activation_port ())
            observer)
      |> Effect.flatten_result

    let observe_delivery_callback ?(cutoff = Cutoff.phys_equal)
        ?(on_finish = []) signal callback =
      let equal = cutoff_equal cutoff in
      let registered = ref None in
      cleanup_observer_registration_on_error
        (fun () ->
          match !registered with
          | None -> Effect.unit
          | Some (O observer) -> abort_observer_registration_effect observer)
        (with_graph_lane_access (fun lane ->
             try
               if not (signal_valid signal) then Error `Invalid_scope
               else
                 let live =
                   {
                     observer_snapshot =
                       Transaction.create_staged Observer_snapshot.initial;
                     obs_owner = None;
                     obs_on_finish = on_finish;
                   }
                 in
                 let rec observer =
                   {
                     obs_id = next_observer_id ();
                     obs_signal = signal;
                     obs_equal = equal;
                     obs_callback =
                       (fun token update -> callback observer token update);
                     obs_state = Observer_lifecycle.Registering live;
                     obs_candidate = false;
                     obs_candidate_previous = None;
                     obs_candidate_next = None;
                   }
                 in
                 live.obs_owner <- Some (O observer);
                 adjust_demand_many lane (observer_reference_demand_roots signal) 1;
                 mark_observer_candidate observer;
                 signal.signal_observers <-
                   O observer :: signal.signal_observers;
                 Graph.add_observer graph lane (O observer);
                 registered := Some (O observer);
                 update_necessity_counters_unlocked lane;
                 Ok observer
             with Graph_error err -> Error err)
         |> Effect.flatten_result)
      |> Effect.bind (fun observer ->
             cleanup_observer_registration_on_error
               (fun () -> abort_observer_registration_effect observer)
               (refresh_timer_demand ()
               |> Effect.bind (fun () -> transfer_active_observer observer)))

    let observe_delivery ?cutoff ?on_finish signal callback =
      observe_delivery_callback ?cutoff ?on_finish signal
        (fun observer token update ->
          callback (delivery observer token update))

    let observe ?cutoff ?on_finish ?(on_update = fun _ -> Effect.unit) signal
        =
      let on_finish =
        match on_finish with
        | None -> []
        | Some hook -> [ (fun reason -> hook (finish_of_lifecycle reason)) ]
      in
      observe_delivery_callback ?cutoff ~on_finish signal
        (fun _observer _token update -> on_update update)

    let read observer =
      with_graph_lane_sync (fun () ->
          Observer_lifecycle.read_value
            ~value_of_live:(fun live ->
              Observer_snapshot.value (observer_current_snapshot live))
            observer.obs_state)
      |> Effect.flatten_result

    let dispose observer = dispose_observer_effect observer
  end

  module For_stream = struct
    type nonrec 'a signal = 'a signal
    type nonrec 'a observer = 'a observer
    type nonrec 'a update = 'a update
    type nonrec observer_error = observer_error
    type observer_finish = Observer.observer_finish
    type 'a delivery = 'a Observer.delivery

    let observe_delivery ?cutoff ?on_finish signal callback =
      let on_finish =
        match on_finish with
        | None -> []
        | Some hook ->
            [ (fun reason -> hook (Observer.finish_of_lifecycle reason)) ]
      in
      Observer.observe_delivery ?cutoff ~on_finish signal callback

    let current handle =
      Observer_core.Delivery_handle.current handle ()
      |> Effect.map (fun current -> Option.map snd current)

    let acknowledge handle =
      let token = Observer_core.Delivery_handle.token handle in
      let update = Observer_core.Delivery_handle.update handle in
      Observer_core.Delivery_handle.acknowledge_sent handle token update

    let dispose = Observer.dispose
  end

  let const value = new_const value

  let map ?(cutoff = Cutoff.phys_equal) f a =
    new_signal ~equal:(cutoff_equal cutoff) (Map (a, f)) [ P a ]

  let map2 ?(cutoff = Cutoff.phys_equal) f a b =
    new_signal ~equal:(cutoff_equal cutoff) (Map2 (a, b, f)) [ P a; P b ]

  let map3 ?(cutoff = Cutoff.phys_equal) f a b c =
    new_signal ~equal:(cutoff_equal cutoff) (Map3 (a, b, c, f))
      [ P a; P b; P c ]

  let map4 ?(cutoff = Cutoff.phys_equal) f a b c d =
    new_signal ~equal:(cutoff_equal cutoff) (Map4 (a, b, c, d, f))
      [ P a; P b; P c; P d ]

  let map5 ?(cutoff = Cutoff.phys_equal) f a b c d e =
    new_signal ~equal:(cutoff_equal cutoff) (Map5 (a, b, c, d, e, f))
      [ P a; P b; P c; P d; P e ]

  let map6 ?(cutoff = Cutoff.phys_equal) f a b c d e f_signal =
    new_signal ~equal:(cutoff_equal cutoff)
      (Map6 (a, b, c, d, e, f_signal, f))
      [ P a; P b; P c; P d; P e; P f_signal ]

  let map7 ?(cutoff = Cutoff.phys_equal) f a b c d e f_signal g =
    new_signal ~equal:(cutoff_equal cutoff)
      (Map7 (a, b, c, d, e, f_signal, g, f))
      [ P a; P b; P c; P d; P e; P f_signal; P g ]

  let map8 ?(cutoff = Cutoff.phys_equal) f a b c d e f_signal g h =
    new_signal ~equal:(cutoff_equal cutoff)
      (Map8 (a, b, c, d, e, f_signal, g, h, f))
      [ P a; P b; P c; P d; P e; P f_signal; P g; P h ]

  let map9 ?(cutoff = Cutoff.phys_equal) f a b c d e f_signal g h i =
    new_signal ~equal:(cutoff_equal cutoff)
      (Map9 (a, b, c, d, e, f_signal, g, h, i, f))
      [ P a; P b; P c; P d; P e; P f_signal; P g; P h; P i ]

  let reduce_balanced ?(cutoff = Cutoff.phys_equal) ~identity ~combine
      signals =
    let inputs = Array.copy signals in
    let length = Array.length inputs in
    if length = 0 then const identity
    else if length = 1 then map ~cutoff (fun value -> value) inputs.(0)
    else
      let rec build lower upper =
        let span = upper - lower in
        if span = 1 then inputs.(lower)
        else
          let middle = lower + (span / 2) in
          let left = build lower middle in
          let right = build middle upper in
          let node_cutoff =
            if lower = 0 && upper = length then cutoff else Cutoff.never
          in
          map2 ~cutoff:node_cutoff combine left right
      in
      build 0 length

  let all ?(cutoff = Cutoff.phys_equal) signals =
    new_signal ~equal:(cutoff_equal cutoff) (All signals)
      (List.map (fun s -> P s) signals)

  let bind ?(cutoff = Cutoff.phys_equal) ~f source =
    make_bind ~equal:(cutoff_equal cutoff) source f

  let observer_count_plan =
    Graph.observer_count_plan ~active:observer_active
      ~invalid:(fun (O observer) ->
        Observer_lifecycle.invalid_scope observer.obs_state)

  let observer_counts lane =
    Graph.observer_counts graph lane observer_count_plan

  let necessary_node_count _lane = Hashtbl.length necessary_nodes

  let dead_node_count lane = Graph.dead_node_count graph lane

  let live_dirty_node_count all_nodes =
    List.fold_left
      (fun count (P signal) ->
        if signal_valid signal && signal.dirty then saturating_succ count else count)
      0 all_nodes

  let keyed_gauges all_nodes =
    List.fold_left
      (fun (node_count, child_count) (P signal) ->
        if signal_valid signal then
          match signal.kind with
          | Keyed keyed ->
              let committed_children =
                keyed.keyed_child_ops.keyed_fold
                  (fun _ _ count -> saturating_succ count)
                  (Transaction.current keyed.keyed_children) 0
              in
              ( saturating_succ node_count,
                saturating_add child_count committed_children )
          | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
          | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
              (node_count, child_count)
        else (node_count, child_count))
      (0, 0) all_nodes

  let stats_counter name value =
    match Debug.stats_counter ~name value with
    | Ok value -> value
    | Error (`Counter_overflow name) -> counter_overflow name

  let stats () =
    with_graph_lane_access (fun lane ->
        try
          let all_nodes = all_nodes_unlocked lane in
          let observer_counts = observer_counts lane in
          let keyed_node_count, keyed_child_count = keyed_gauges all_nodes in
          Ok
            {
              pure_snapshot_commit_count =
                stats_counter "stats pure_snapshot_commit_count"
                  (Graph.pure_snapshot_commit_count graph lane);
              callback_delivery_count =
                stats_counter "stats callback_delivery_count"
                  (Graph.counter graph lane Graph.Callback_delivery_count);
              total_node_count =
                stats_counter "stats total_node_count" (List.length all_nodes);
              active_observer_count =
                stats_counter "stats active_observer_count"
                  (Graph.observer_counts_active observer_counts);
              invalid_observer_count =
                stats_counter "stats invalid_observer_count"
                  (Graph.observer_counts_invalid observer_counts);
              necessary_node_count =
                stats_counter "stats necessary_node_count"
                  (necessary_node_count lane);
              dead_node_count =
                stats_counter "stats dead_node_count" (dead_node_count lane);
              live_dirty_node_count =
                stats_counter "stats live_dirty_node_count"
                  (live_dirty_node_count all_nodes);
              recompute_count =
                stats_counter "stats recompute_count"
                  (Graph.counter graph lane Graph.Recompute_count);
              dynamic_scope_invalidations =
                stats_counter "stats dynamic_scope_invalidations"
                  (Graph.counter graph lane Graph.Dynamic_scope_invalidations);
              nodes_became_necessary =
                stats_counter "stats nodes_became_necessary"
                  (Graph.counter graph lane Graph.Nodes_became_necessary);
              nodes_became_unnecessary =
                stats_counter "stats nodes_became_unnecessary"
                  (Graph.counter graph lane Graph.Nodes_became_unnecessary);
              lane_waiter_count =
                stats_counter "stats lane_waiter_count"
                  (Graph.lane_waiting_count graph lane);
              lane_cancelled_waiter_count =
                stats_counter "stats lane_cancelled_waiter_count"
                  (Graph.lane_cancelled_count graph lane);
              keyed =
                {
                  node_count =
                    stats_counter "stats keyed.node_count" keyed_node_count;
                  committed_child_count =
                    stats_counter "stats keyed.committed_child_count"
                      keyed_child_count;
                  reconciliation_count =
                    stats_counter "stats keyed.reconciliation_count"
                      keyed_counters.reconciliation_count;
                  input_key_comparison_count =
                    stats_counter "stats keyed.input_key_comparison_count"
                      keyed_counters.input_key_comparison_count;
                  input_diff_event_count =
                    stats_counter "stats keyed.input_diff_event_count"
                      keyed_counters.input_diff_event_count;
                  child_visit_count =
                    stats_counter "stats keyed.child_visit_count"
                      keyed_counters.child_visit_count;
                  provisional_addition_count =
                    stats_counter "stats keyed.provisional_addition_count"
                      keyed_counters.provisional_addition_count;
                  committed_addition_count =
                    stats_counter "stats keyed.committed_addition_count"
                      keyed_counters.committed_addition_count;
                  committed_removal_count =
                    stats_counter "stats keyed.committed_removal_count"
                      keyed_counters.committed_removal_count;
                  reconciliation_rollback_count =
                    stats_counter "stats keyed.reconciliation_rollback_count"
                      keyed_counters.reconciliation_rollback_count;
                };
            }
        with Graph_error err -> Error err)
    |> Effect.flatten_result

  let signal_selected :
      type a. dot_options -> (int, packed_signal) Hashtbl.t -> a signal -> bool =
   fun options necessary signal ->
    match options.dot_scope with
    | `Necessary -> Hashtbl.mem necessary (signal_id_int signal.id)
    | `All_valid -> signal_valid signal
    | `All_including_invalid -> true

  let signal_state_snapshot : type a. a signal -> Debug.signal_state_snapshot =
   fun signal ->
    let snapshot = signal_current_snapshot signal in
    let signal_var =
      match signal.kind with
      | Var source ->
          Some
            {
              Debug.signal_var_id_label = var_id_label source.var_id;
              signal_var_queued = source.queued;
              signal_var_updating = source.updating;
            }
      | Const _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _ | Map6 _ | Map7 _
      | Map8 _ | Map9 _ | All _ | Bind _ | Keyed _ ->
          None
    in
    {
      Debug.signal_valid = signal_valid signal;
      signal_initialized = Signal_snapshot.is_initialized snapshot;
      signal_dirty = signal.dirty;
      signal_computing = signal.computing;
      signal_dependency_count = Topology.length signal.dependencies;
      signal_dependent_count = Topology.length signal.dependents;
      signal_var;
    }

  let signal_scope_snapshot : type a. a signal -> Debug.signal_scope_snapshot =
   fun signal ->
    match signal.scope with
    | None -> Debug.Signal_root_scope
    | Some scope ->
        let parent =
          match Scope.parent scope with
          | None -> "root"
          | Some parent -> scope_id_label (Scope.id parent)
        in
        Debug.Signal_child_scope
          {
            signal_scope_id_label = scope_id_label (Scope.id scope);
            signal_scope_valid = Scope.valid scope;
            signal_scope_owner_label = signal_id_label (scope_owner_id scope);
            signal_scope_parent_label = parent;
          }

  let debug_timer_snapshot (timer : Timer_policy.debug_snapshot) =
    Timer_policy.debug_snapshot_result timer
      ~plan:(fun ~state_label:_ ~active ~running_generation ~has_cancel
                 ~finished ~generation ->
        {
          Debug.timer_active = active;
          timer_running_generation = running_generation;
          timer_has_cancel = has_cancel;
          timer_finished = finished;
          timer_generation = generation;
        })

  let signal_timer_fields : type a. a signal -> string list =
   fun signal ->
    match signal.timer with
    | None -> []
    | Some timer ->
        Debug.timer_fields
          ~state_label:(timer_state_label (timer_current_state timer))
          (debug_timer_snapshot (timer_debug_snapshot timer))

  let dead_signal_state_snapshot dead =
    {
      Debug.signal_valid = false;
      signal_initialized = dead.dead_initialized;
      signal_dirty = dead.dead_dirty;
      signal_computing = dead.dead_computing;
      signal_dependency_count = dead.dead_dependency_count;
      signal_dependent_count = dead.dead_dependent_count;
      signal_var = None;
    }

  let dead_signal_scope_snapshot dead =
    match
      ( dead.dead_scope_id,
        dead.dead_scope_owner,
        dead.dead_scope_parent,
        dead.dead_scope_valid )
    with
    | None, None, None, None -> Debug.Signal_root_scope
    | Some scope_id, Some owner, parent, Some scope_valid ->
        Debug.Signal_child_scope
          {
            signal_scope_id_label = scope_id_label scope_id;
            signal_scope_valid = scope_valid;
            signal_scope_owner_label = signal_id_label owner;
            signal_scope_parent_label =
              Option.fold ~none:"root"
                ~some:(fun parent -> scope_id_label parent)
                parent;
          }
    | _ -> invalid_arg "Eta_signal: inconsistent dead signal scope"

  let dead_timer_fields = function
    | None -> []
    | Some timer -> Debug.timer_fields (debug_timer_snapshot timer)

  let signal_label : type a. dot_options -> a signal -> string =
   fun options signal ->
    let requested_scope =
      match options.dot_scope with
      | `Necessary -> "necessary"
      | `All_valid -> "all_valid"
      | `All_including_invalid -> "all_including_invalid"
    in
    let signal_extra_fields =
      if options.dot_state then
        match signal.kind with
        | Keyed keyed ->
            let child_count =
              keyed.keyed_child_ops.keyed_fold
                (fun _ _ count -> saturating_succ count)
                (Transaction.current keyed.keyed_children) 0
            in
            [
              "committed_children=" ^ string_of_int child_count;
              "requested_scope=" ^ requested_scope;
            ]
        | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
        | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
            []
      else []
    in
    Debug.signal_label
      {
        Debug.signal_kind_label = kind_name signal.kind;
        signal_id_label = signal_id_label signal.id;
        signal_tombstone = false;
        signal_state =
          (if options.dot_state then Some (signal_state_snapshot signal)
           else None);
        signal_scope =
          (if options.dot_dynamic_scopes then
             Some (signal_scope_snapshot signal)
           else None);
        signal_extra_fields;
        signal_timer_fields =
          (if options.dot_timers then signal_timer_fields signal else []);
      }

  let dead_signal_label options dead =
    let signal_extra_fields =
      if options.dot_state then
        match dead.dead_keyed_child_count with
        | None -> []
        | Some child_count ->
            let requested_scope =
              match options.dot_scope with
              | `Necessary -> "necessary"
              | `All_valid -> "all_valid"
              | `All_including_invalid -> "all_including_invalid"
            in
            [
              "committed_children=" ^ string_of_int child_count;
              "requested_scope=" ^ requested_scope;
            ]
      else []
    in
    Debug.signal_label
      {
        Debug.signal_kind_label = dead.dead_kind;
        signal_id_label = signal_id_label dead.dead_id;
        signal_tombstone = true;
        signal_state =
          (if options.dot_state then Some (dead_signal_state_snapshot dead)
           else None);
        signal_scope =
          (if options.dot_dynamic_scopes then
             Some (dead_signal_scope_snapshot dead)
           else None);
        signal_extra_fields;
        signal_timer_fields =
          (if options.dot_timers then dead_timer_fields dead.dead_timer else []);
      }

  let observer_label ?missing_observed_signal_id (O observer) =
    let value_state_label, delivery_state_label =
      match observer.obs_state with
      | Observer_lifecycle.Registering live | Observer_lifecycle.Active live ->
          let snapshot = observer_current_snapshot live in
          ( Observer_core.Value.label (Observer_snapshot.value snapshot),
            Observer_core.Delivery.label
              (Observer_snapshot.delivery snapshot) )
      | Observer_lifecycle.Disposed value | Observer_lifecycle.Invalid_scope value
        ->
          (Observer_core.Value.label value, "none")
    in
    Debug.observer_label
      {
        Debug.observer_id_label = observer_id_label observer.obs_id;
        observer_state_label = Observer_lifecycle.label observer.obs_state;
        observer_value_state_label = value_state_label;
        observer_delivery_state_label = delivery_state_label;
        observer_missing_observed_signal_id_label =
          Option.map signal_id_label missing_observed_signal_id;
      }

  let observer_selected ~include_invalid (O observer) =
    Observer_lifecycle.diagnostic_visible ~include_invalid observer.obs_state

  let to_dot ?(options = default_dot_options) () =
    with_graph_lane_access @@ fun lane ->
    let necessary = necessary_nodes in
    let all_nodes = all_nodes_unlocked lane in
    let selected signal = signal_selected options necessary signal in
    let include_dead_nodes =
      match options.dot_scope with
      | `All_including_invalid -> true
      | `Necessary | `All_valid -> false
    in
    let live_ids = Hashtbl.create 16 in
    let dead_ids = Hashtbl.create 16 in
    if include_dead_nodes then
      Graph.iter_dead_nodes graph lane ~f:(fun tombstone ->
          Hashtbl.replace dead_ids tombstone.dead_id ());
    let selected_live_signal signal =
      selected signal
      && not
           (include_dead_nodes && (not (signal_valid signal))
          && Hashtbl.mem dead_ids signal.id)
    in
    List.iter
      (fun (P signal) ->
        if selected_live_signal signal then
          Hashtbl.replace live_ids signal.id ())
      all_nodes;
    let selected_id id = Hashtbl.mem live_ids id || Hashtbl.mem dead_ids id in
    let dot_signal_id id =
      if Hashtbl.mem live_ids id then signal_id_label id
      else dead_signal_id_label id
    in
    let live_dot_nodes =
      all_nodes
      |> List.filter_map (fun (P signal) ->
             if selected_live_signal signal then
               Some
                 {
                   Debug.dot_node_id = signal_id_label signal.id;
                   dot_node_label = signal_label options signal;
                   dot_node_dependency_ids =
                     List.filter_map
                       (fun (P dependency) ->
                         if selected_id dependency.id then
                           Some (dot_signal_id dependency.id)
                         else None)
                       (signal_dependencies signal);
                 }
             else None)
    in
    let dead_dot_nodes =
      if include_dead_nodes then
        Graph.map_dead_nodes graph lane ~f:(fun tombstone ->
            {
              Debug.dot_node_id = dead_signal_id_label tombstone.dead_id;
              dot_node_label = dead_signal_label options tombstone;
              dot_node_dependency_ids =
                List.filter_map
                  (fun dependency_id ->
                    if selected_id dependency_id then
                      Some (dot_signal_id dependency_id)
                    else None)
                  tombstone.dead_dependency_ids;
            })
      else []
    in
    let dot_observers =
      if options.dot_observers then
        let diagnostics =
          Graph.observer_diagnostics
            ~visible:(observer_selected ~include_invalid:include_dead_nodes)
            ~diagnostic:(fun (O observer as packed) ->
              let observed_signal_selected = selected_id observer.obs_signal.id in
              let missing_observed_signal_id =
                if include_dead_nodes && not observed_signal_selected then
                  Some observer.obs_signal.id
                else None
              in
              {
                Debug.dot_observer_id = observer_id_label observer.obs_id;
                dot_observer_label =
                  observer_label ?missing_observed_signal_id packed;
                dot_observed_signal_id =
                  (if observed_signal_selected then
                     Some (dot_signal_id observer.obs_signal.id)
                   else None);
              })
        in
        Graph.collect_observer_diagnostics graph lane diagnostics
      else []
    in
    Debug.render_dot ~nodes:(live_dot_nodes @ dead_dot_nodes)
      ~observers:dot_observers

  module Time = struct
    type monotonic_time = {
      runtime_contract : Runtime_contract.t;
      ms : int;
    }

    let to_ms timestamp = timestamp.ms

    let monotonic_time_equal left right =
      Runtime_contract.same_runtime left.runtime_contract right.runtime_contract
      && Int.equal left.ms right.ms

    let validate_timestamp_runtime runtime_contract timestamp =
      if
        Runtime_contract.same_runtime runtime_contract timestamp.runtime_contract
      then Ok ()
      else Error `Runtime_mismatch

    let validate_interval duration =
      Timer_policy.validate_interval_ms (Duration.to_ms duration)

    let validate_future now deadline_ms =
      Timer_policy.validate_future_deadline ~now_ms:now ~deadline_ms

    let validate_positive_duration duration =
      Timer_policy.validate_positive_duration_ms (Duration.to_ms duration)

    let timer_set_source timer generation (source : 'a var) value =
      with_graph_lane_access (fun lane ->
          Timer.publish_if_running timer_state_port timer ~generation
            ~publish:(fun () ->
              publish_source_current source.source_value value;
              Var.queue_var lane source))

    let add_relative_deadline = Timer_policy.add_relative_deadline

    let add timestamp duration =
      add_relative_deadline timestamp.ms (Duration.to_ms duration)
      |> Result.map (fun ms -> { timestamp with ms })

    let attach_timer ?(update_on_start = false) ?(refresh_when_inactive = true)
        ?refresh_operation ~runtime_contract signal schedule update =
      let timer =
        Timer.create_daemon_node ~runtime_contract ~refresh_when_inactive
          ~refresh_operation
          (Timer.daemon_context
             ~advance_generation:(checked_succ "timer generation")
             ~state_access:
               (Timer.daemon_state_access
                  ~with_state:{ run_state = (fun f -> with_graph_lane_sync f) })
             ~state:timer_state_port
             ~update:
               (Timer.daemon_update
                  ~update:
                    { run_update =
                      (fun timer ~generation ~missed ->
                        update.timer_update timer generation ~missed)
                    })
             ~hooks:
               (Timer.daemon_hooks
                  ~after_due_read_before_commit:{ run_hook = (fun () -> Effect.unit) }
                  ~after_update_constructed_before_run:{ run_hook = (fun () -> Effect.unit) })
             ~on_lifecycle_mismatch:(fun _timer ->
               link_timer_reconcile (P signal)))
          ~schedule ~update_on_start
          ~catch_up_policy:update.timer_catch_up_policy
      in
      signal.timer <- Some timer;
      Hashtbl.replace timer_nodes signal.id (P signal);
      signal

    let timer_refresh_operation source spec =
      Refresh_operation (source, spec)

    let make_timer_signal ?(cutoff = Cutoff.phys_equal) initial schedule
        ~runtime_contract source_policy update =
      let source = Var.create ~cutoff initial in
      let signal = Var.watch source in
      Timer_policy.source_policy_result source_policy
        ~plan:
          (fun ~update_on_start ~catch_up_policy ~refresh_when_inactive
               ~refresh_on_demand ->
            let refresh_operation =
              Option.map (timer_refresh_operation source) refresh_on_demand
            in
            attach_timer ~update_on_start ~refresh_when_inactive
              ?refresh_operation ~runtime_contract signal schedule
              {
                timer_catch_up_policy = catch_up_policy;
                timer_update =
                  (fun timer generation ~missed ->
                    update.source_timer_update timer generation ~missed source);
              })

    let construct_timer_signal f =
      with_graph_lane_sync (fun () ->
          try
            ignore
              (graph_result_or_raise (Graph.allocation_scope graph scope_ops));
            Ok (f ())
          with Graph_error err -> Error (err :> time_error))
      |> Effect.flatten_result

    let now ~every =
      Effect.sync (fun () -> validate_interval every)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    Effect.now_ms
                    |> Effect.bind (fun initial_ms ->
                           construct_timer_signal (fun () ->
                               let now_ms_signal =
                                 make_timer_signal
                                   ~cutoff:(Cutoff.of_equal Int.equal)
                                   initial_ms
                                   (Timer_policy.Periodic
                                      (Duration.to_ms every))
                                   ~runtime_contract
                                   (Timer_policy.current_time_source_policy ())
                                   {
                                     source_timer_update =
                                       (fun timer generation ~missed:_ source ->
                                         Effect.now_ms
                                         |> Effect.bind (fun now_ms ->
                                                timer_set_source timer generation
                                                  source now_ms
                                                |> Effect.map (fun _ -> ())));
                                   }
                               in
                               map ~cutoff:(Cutoff.of_equal monotonic_time_equal)
                                 (fun ms -> { runtime_contract; ms })
                                 now_ms_signal))))

    let construct_deadline_signal deadline_ms ~runtime_contract =
      construct_timer_signal (fun () ->
          make_timer_signal ~cutoff:(Cutoff.of_equal Bool.equal) false
            (Timer_policy.One_shot deadline_ms) ~runtime_contract
            (Timer_policy.deadline_source_policy ~deadline_ms)
            {
              source_timer_update =
                (fun timer generation ~missed:_ source ->
                  Effect.now_ms
                  |> Effect.bind (fun now_ms ->
                         if now_ms >= deadline_ms then
                           timer_set_source timer generation source true
                           |> Effect.bind (function
                                | `Updated ->
                                    with_graph_lane_sync (fun () ->
                                        timer_finish_unlocked timer)
                                | `Stopped -> Effect.unit)
                         else
                           timer_set_source timer generation source false
                           |> Effect.map (fun _ -> ())));
            })

    let deadline deadline =
      let deadline_ms = to_ms deadline in
      current_runtime_contract ()
      |> Effect.bind (fun runtime_contract ->
             Effect.from_result
               (validate_timestamp_runtime runtime_contract deadline)
             |> Effect.bind (fun () ->
                    Effect.now_ms
                    |> Effect.bind (fun now_ms ->
                           Effect.from_result
                             (validate_future now_ms deadline_ms)
                           |> Effect.bind (fun () ->
                                  construct_deadline_signal deadline_ms
                                    ~runtime_contract))))

    let after duration =
      Effect.sync (fun () -> validate_positive_duration duration)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    Effect.now_ms
                    |> Effect.bind (fun now_ms ->
                           Effect.from_result
                             (add_relative_deadline now_ms
                                (Duration.to_ms duration))
                           |> Effect.bind (fun deadline_ms ->
                                  construct_deadline_signal deadline_ms
                                    ~runtime_contract))))

    let interval interval =
      Effect.sync (fun () -> validate_interval interval)
      |> Effect.flatten_result
      |> Effect.bind (fun () ->
             current_runtime_contract ()
             |> Effect.bind (fun runtime_contract ->
                    construct_timer_signal (fun () ->
                        let interval_ms = Duration.to_ms interval in
                        make_timer_signal ~cutoff:(Cutoff.of_equal Int.equal) 0
                          (Timer_policy.Periodic interval_ms)
                          ~runtime_contract
                          (Timer_policy.interval_source_policy ~interval_ms)
                          {
                            source_timer_update =
                              (fun timer generation ~missed source ->
                                Effect.sync (fun () ->
                                    add_int_capped (Var.value source) missed)
                                |> Eta_observability.annotate
                                     ~key:"eta_signal.timer.kind"
                                     ~value:"interval"
                                |> Eta_observability.named
                                     "eta_signal.time.interval"
                                |> Effect.bind (fun next ->
                                       timer_set_source timer generation source
                                         next
                                       |> Effect.map (fun _ -> ())));
                          })))

  end


  module Extension = struct
    type nonrec 'a signal = 'a signal
    type dirty_listener = unit -> unit
    type token = Obj.t

    let demand_counter_snapshot () = Demand.counter_snapshot demand_counters

    let scheduler_empty () = Scheduler.is_empty scheduler
    let actionable_work_count () = Work.total work

    let timer_reconciliation_work_count () =
      Work.count work Work.Timer_reconciliation

    let cleanup_work_count () = Work.count work Work.Cleanup

    type nonrec work_class = Work.class_ =
      | Sources
      | Scheduler
      | Observer_delivery
      | Timer_reconciliation
      | Cleanup

    let work_count class_ = Work.count work class_

    type atomic_fault = Atomic_pass.fault

    let set_atomic_pass_fault fault =
      Atomic_pass.set_fault (Graph.atomic_pass_fault_injector graph) fault

    let signal_token (type a) (signal : a signal) : token = Obj.repr signal

    let packed_signal_of_token token : packed_signal = P (Obj.obj token)

    let signal_valid_token token =
      let (P signal) = packed_signal_of_token token in
      signal_valid signal

    let signal_demand_token token =
      let (P signal) = packed_signal_of_token token in
      signal.demand

    let dependent_edge_count_token token =
      let (P signal) = packed_signal_of_token token in
      Topology.length signal.dependents

    let dependent_parent_tokens_token token =
      let (P signal) = packed_signal_of_token token in
      Topology.fold signal.dependents ~init:[] ~f:(fun parents edge ->
          let (P parent) = edge.parent in
          Obj.repr parent :: parents)

    let has_dependent_edge_token ~child ~parent =
      let parent = signal_token parent in
      List.exists
        (fun candidate -> candidate == parent)
        (dependent_parent_tokens_token child)

    let reset_counters () =
      Atomic_pass.reset_counters (Graph.atomic_pass_counters graph);
      Demand.reset_counters demand_counters;
      Scheduler.reset_counters scheduler_counters;
      Topology.reset_counters topology_counters;
      Work.reset_counters work_counters;
      Observer_plan.reset_counters observer_plan_counters;
      Observer_delivery_counters.reset_counters observer_delivery_counters;
      Eta_signal_tombstone_index.reset_counters (Graph.tombstone_counters graph)

    let tombstone_counter_snapshot () =
      Eta_signal_tombstone_index.counter_snapshot
        (Graph.tombstone_counters graph)

    let atomic_pass_counter_snapshot () =
      Atomic_pass.counter_snapshot (Graph.atomic_pass_counters graph)

    let scheduler_counter_snapshot () =
      Scheduler.counter_snapshot scheduler_counters

    let topology_counter_snapshot () =
      Topology.counter_snapshot topology_counters

    let work_counter_snapshot () = Work.counter_snapshot work_counters

    let observer_plan_counter_snapshot () =
      Observer_plan.counter_snapshot observer_plan_counters

    let observer_delivery_counter_snapshot () =
      Observer_delivery_counters.counter_snapshot observer_delivery_counters

    let generation () =
      with_graph_lane_access (fun lane -> Graph.generation graph lane)

    type nonrec 'a keyed_change = 'a keyed_change =
      | Keyed_left of 'a
      | Keyed_right of 'a
      | Keyed_changed of 'a * 'a

    type nonrec ('key, 'value, 'map) keyed_map_ops =
      ('key, 'value, 'map) keyed_map_ops

    type nonrec ('key, 'data, 'map) keyed_input_ops =
      ('key, 'data, 'map) keyed_input_ops

    type nonrec ('key, 'output, 'map) keyed_output_ops =
      ('key, 'output, 'map) keyed_output_ops

    type keyed_entry_identity = {
      keyed_key_token : token;
      keyed_scope_token : token;
      keyed_source_token : token;
      keyed_data_signal_token : token;
      keyed_child_signal_token : token;
      keyed_edge_attached : bool;
    }

    type keyed_event =
      | Detached of token
      | Invalidated of token
      | Attached of token

    type nonrec keyed_counter = keyed_counter =
      | Reconciliation_count
      | Input_key_comparison_count
      | Input_diff_event_count
      | Child_visit_count
      | Provisional_addition_count
      | Committed_addition_count
      | Committed_removal_count
      | Reconciliation_rollback_count

    type preflight_plan =
      | Preflight_plan : packed_signal * (unit -> unit) -> preflight_plan

    let add_dirty_listener = add_dirty_listener
    let remove_dirty_listener = remove_dirty_listener

    let preflight_plan owner run = Preflight_plan (P owner, run)

    let preflight_owner_before_descendant plans =
      plans
      |> List.sort (fun (Preflight_plan (left, _))
                         (Preflight_plan (right, _)) ->
             compare_signal_scope_then_id left right)
      |> List.iter (fun (Preflight_plan (_, run)) -> run ())

    let keyed_entry_identity :
        type output key.
        output signal -> key -> keyed_entry_identity option =
     fun owner key ->
      match owner.kind with
      | Keyed keyed -> (
          let key = Obj.magic key in
          match
            keyed.keyed_child_ops.keyed_find_opt key
              (Transaction.current keyed.keyed_children)
          with
          | None -> None
          | Some child ->
              Some
                {
                  keyed_key_token = Obj.repr child.keyed_child_key;
                  keyed_scope_token = Obj.repr child.keyed_child_scope;
                  keyed_source_token = Obj.repr child.keyed_child_source;
                  keyed_data_signal_token = Obj.repr child.keyed_child_data;
                  keyed_child_signal_token = Obj.repr child.keyed_child_output;
                  keyed_edge_attached =
                    Hashtbl.mem owner.dependency_index
                      (signal_id_int child.keyed_child_output.id);
                })
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
          invalid_arg "Eta_signal_kernel.Extension: not a keyed signal"

    let keyed_scope_valid token =
      Scope.valid (Obj.obj token)

    let keyed_pending : type output. output signal -> bool =
     fun owner ->
      match owner.kind with
      | Keyed keyed -> Option.is_some keyed.keyed_pending
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
          invalid_arg "Eta_signal_kernel.Extension: not a keyed signal"

    let set_keyed_preflight :
        type output. output signal -> (unit -> unit) -> unit =
     fun owner preflight ->
      match owner.kind with
      | Keyed keyed -> keyed.keyed_preflight <- preflight
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
          invalid_arg "Eta_signal_kernel.Extension: not a keyed signal"

    let set_keyed_event_recorder :
        type output.
        output signal -> (keyed_event -> unit) -> unit =
     fun owner record ->
      match owner.kind with
      | Keyed keyed ->
          keyed.keyed_record_event <- (function
            | Keyed_detached scope -> record (Detached (Obj.repr scope))
            | Keyed_invalidated scope -> record (Invalidated (Obj.repr scope))
            | Keyed_attached scope -> record (Attached (Obj.repr scope)))
      | Const _ | Var _ | Map _ | Map2 _ | Map3 _ | Map4 _ | Map5 _
      | Map6 _ | Map7 _ | Map8 _ | Map9 _ | All _ | Bind _ ->
          invalid_arg "Eta_signal_kernel.Extension: not a keyed signal"

    let set_keyed_counter = set_keyed_counter

    let keyed_mapi
        ?(data_cutoff = Cutoff.phys_equal)
        ~data_ops ~output_ops input ~f =
      let child_ops = keyed_child_ops data_ops.keyed_compare_key in
      let keyed =
        {
          keyed_input = input;
          keyed_data_cutoff = data_cutoff;
          keyed_builder = f;
          keyed_data_ops = data_ops;
          keyed_output_ops = output_ops;
          keyed_child_ops = child_ops;
          keyed_raw_input = Transaction.create_staged data_ops.keyed_input_empty;
          keyed_children = Transaction.create_staged child_ops.keyed_empty;
          keyed_affected = child_ops.keyed_empty;
          keyed_owner = None;
          keyed_preflight = (fun () -> ());
          keyed_record_event = (fun _event -> ());
          keyed_pending = None;
        }
      in
      let owner = new_signal (Keyed keyed) [ P input ] in
      keyed.keyed_owner <- Some owner;
      owner
  end

  module Package = struct
    type nonrec 'a signal = 'a signal

    type 'a change =
      | Left of 'a
      | Right of 'a
      | Changed of 'a * 'a

    type ('key, 'data, 'map) input_ops = {
      empty : 'map;
      compare_key : 'key -> 'key -> int;
      fold_symmetric_diff :
        'acc.
        'map ->
        'map ->
        on_compare:(unit -> unit) ->
        init:'acc ->
        f:('acc -> 'key -> 'data change -> 'acc) ->
        'acc;
    }

    type ('key, 'output, 'map) output_ops = {
      empty : 'map;
      set : 'key -> 'output -> 'map -> 'map;
      remove : 'key -> 'map -> 'map;
    }

    type 'a plan = Plan of (unit -> 'a signal)

    let stable_family ?data_cutoff ~input
        ~(input_ops : (_, _, _) input_ops)
        ~(output_ops : (_, _, _) output_ops) ~build () =
      let data_ops =
        {
          keyed_input_empty = input_ops.empty;
          keyed_compare_key = input_ops.compare_key;
          keyed_fold_symmetric_diff =
            (fun left right ~on_compare ~init ~f ->
            input_ops.fold_symmetric_diff left right ~on_compare ~init
              ~f:(fun acc key -> function
                | Left value -> f acc key (Keyed_left value)
                | Right value -> f acc key (Keyed_right value)
                | Changed (previous, current) ->
                    f acc key (Keyed_changed (previous, current))));
        }
      in
      let output_ops =
        {
          keyed_output_empty = output_ops.empty;
          keyed_output_set = output_ops.set;
          keyed_output_remove = output_ops.remove;
        }
      in
      Plan (fun () ->
          Extension.keyed_mapi ?data_cutoff ~data_ops ~output_ops input
            ~f:build)

    let install (Plan install) = install ()
  end
end

module Make_no_error () = Make (No_observer_error) ()
