open Crux_engine

module Failure = Crux_failure.Failure
module Projection = Crux_projection

type post_kind =
  | Normal
  | Stop
  | Crash

type post_commit = {
  root : root_core;
  kind : post_kind;
  works : work list;
  cancellations : owned_job list;
  (* [started] is claimed with a single compare-and-set: the fused
     empty-batch path and the locked non-empty path agree on the atomic, so
     exactly one [start] wins regardless of which path a batch takes. *)
  started : bool Atomic.t;
}

let work_failure_effect (root : root_core) (work : work) =
  let open Eta.Syntax in
  let program =
    match work.payload with
    | Program program -> program
    | Source_open _ ->
        invalid_arg "Eta_crux: source opening admitted as a running program"
  in
  let* exit = Eta.Effect.to_exit program in
  (match work.observation with
  | None -> ()
  | Some observation ->
      let settlement =
        match exit with
        | Eta.Exit.Ok () -> Crux_testing.Testing.Succeeded
        | Eta.Exit.Error cause
          when Eta.Cause.is_interrupt_only cause ->
            Crux_testing.Testing.Interrupted
        | Eta.Exit.Error _ -> Crux_testing.Testing.Failed
      in
      Crux_testing.settled observation settlement);
  match exit with
  | Eta.Exit.Ok () -> Eta.Effect.unit
  | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause ->
      Eta.Effect.unit
  | Eta.Exit.Error cause ->
      Eta.Effect.sync (fun () ->
          let origin, trigger =
            Eta.Sync_lock.use root.lock @@ fun () ->
            if Atomic.get root.stop_requested then
              (Failure.Cleanup, Failure.Stop_teardown)
            else
              match Atomic.get root.failure with
              | Some _ -> (Failure.Cleanup, Failure.Crash_teardown)
              | None -> (work.origin, work.trigger)
          in
          let packed =
            Failure.Packed_cause.make
              ~pp_error:(fun _ (value : never) -> absurd value)
              cause
          in
          latch_failure_record root
            (failure_record root ~origin ~trigger packed))

let remove_job (root : root_core) (job : owned_job) =
  Eta.Sync_lock.use root.lock @@ fun () ->
  match Int_map.find_opt job.scope root.scopes with
  | None -> ()
  | Some scope ->
      scope.jobs <-
        List.filter
          (fun (candidate : owned_job) -> candidate != job)
          scope.jobs

let run_owned_job (root : root_core) (work : work) (job : owned_job) =
  let open Eta.Syntax in
  let cancellation =
    let* descendants = Eta.Promise.await job.cancel in
    descendants
    |> List.map (fun (descendant : owned_job) ->
           Eta.Promise.await descendant.settled)
    |> Eta.Effect.concat
  in
  let monitored =
    Eta.Effect.with_background (work_failure_effect root work) (fun () ->
        cancellation)
  in
  let* exit = Eta.Effect.to_exit monitored in
  let* () =
    (match exit with
    | Eta.Exit.Ok () -> Eta.Effect.unit
    | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause ->
        Eta.Effect.unit
    | Eta.Exit.Error cause ->
        Eta.Effect.sync (fun () ->
            let packed =
              Failure.Packed_cause.make
                ~pp_error:(fun _ (value : never) -> absurd value)
                cause
            in
            latch_failure_record root
              (failure_record root ~origin:Failure.Cleanup
                 ~trigger:Failure.Crash_teardown packed)))
  in
  let* () = Eta.Effect.sync (fun () -> remove_job root job) in
  let+ _ = Eta.Promise.resolve job.settled (Eta.Exit.Ok ()) in
  ()

let start_owned_job (root : root_core) (work : work) =
  let cancel = Eta.Promise.create () in
  let settled = Eta.Promise.create () in
  let job =
    Eta.Sync_lock.use root.lock @@ fun () ->
    match Int_map.find_opt work.scope root.scopes with
    | Some scope when scope.active ->
        let rec ancestors current acc =
          match Int_map.find_opt current root.scopes with
          | Some { parent = Some parent; _ } ->
              ancestors parent (parent :: acc)
          | Some { parent = None; _ } | None -> acc
        in
        let job =
          {
            scope = work.scope;
            ancestors = ancestors work.scope [];
            cancel;
            settled;
          }
        in
        scope.jobs <- job :: scope.jobs;
        Some job
    | Some _ | None -> None
  in
  match job with
  | Some job ->
      Option.iter Crux_testing.started work.observation;
      Eta.Spi.daemon
        (with_owned_context root work.scope
           (run_owned_job root work job))
  | None ->
      Option.iter Crux_testing.discarded work.observation;
      Eta.Effect.unit

let discard_observed_works works =
  List.iter
    (fun work ->
      Option.iter Crux_testing.discarded work.observation)
    works

let request_job_cancellations (jobs : owned_job list) =
  jobs
  |> List.map (fun (job : owned_job) ->
         let descendants =
           List.filter
             (fun (candidate : owned_job) ->
               List.mem job.scope candidate.ancestors)
             jobs
         in
         Eta.Promise.resolve job.cancel (Eta.Exit.Ok descendants)
         |> Eta.Effect.map (fun _ -> ()))
  |> Eta.Effect.concat

let await_job_settlement (jobs : owned_job list) =
  jobs
  |> List.map (fun (job : owned_job) -> Eta.Promise.await job.settled)
  |> Eta.Effect.concat

let widen_never eff = Eta.Effect.map_error absurd eff

let open_sources (root : root_core) works =
  if works = [] then Eta.Effect.pure []
  else
  let openings =
    works
    |> List.map (fun work ->
           let opening =
             match work.payload with
             | Program _ ->
                 invalid_arg
                   "Eta_crux: running program admitted as source opening"
             | Source_open opening -> opening
           in
           Eta.Effect.to_exit opening
           |> Eta.Effect.map (function
                | Eta.Exit.Ok running ->
                    Option.map
                      (fun program ->
                        {
                          work with
                          trigger = Failure.Source_producer;
                          payload = Program program;
                        })
                      running
                | Eta.Exit.Error cause
                  when Eta.Cause.is_interrupt_only cause ->
                    None
                | Eta.Exit.Error cause ->
                    let packed =
                      Failure.Packed_cause.make
                        ~pp_error:(fun _ (value : never) ->
                          absurd value)
                        cause
                    in
                    latch_failure_record root
                      (failure_record root ~origin:work.origin
                         ~trigger:work.trigger packed);
                    None))
    |> Eta.Effect.all
    |> Eta.Effect.map (fun results -> `Opened results)
  in
  let terminal =
    Eta.Queue.take root.terminal_wake
    |> Eta.Effect.map_error (function
         | `Closed -> ()
         | `Closed_with_error (_ : never) -> .)
    |> Eta.Effect.ignore_errors
    |> Eta.Effect.map (fun () -> `Terminal)
  in
  Eta.Effect.race [ openings; terminal ]
  |> Eta.Effect.map (function
       | `Opened results -> List.filter_map Fun.id results
       | `Terminal -> [])

let all_live_jobs (root : root_core) =
  Eta.Sync_lock.use root.lock @@ fun () ->
  Int_map.fold
    (fun _ (scope : scope_state) jobs -> List.rev_append scope.jobs jobs)
    root.scopes []

let close_request_exports (root : root_core) reason =
  let closers =
    Int_map.fold
      (fun _ (export : boundary_export) closers ->
        match export.kind with
        | Boundary_request { close_all; _ } -> close_all :: closers
        | Boundary_endpoint _ -> closers)
      root.boundary_exports []
  in
  List.iter (fun close_all -> close_all reason) closers

module Post_commit = struct
  type t = post_commit
  type start_error = Already_started

  type start_result =
    | Admitted
    | Stop_settled
    | Crash_settled of Failure.settlement

  let close (root : root_core) =
    Eta.Sync_lock.use root.lock @@ fun () -> Atomic.set root.phase Closed

  let settle_stop root =
    let open Eta.Syntax in
    Crux_telemetry.root_teardown
      (let* () =
         Eta.Effect.sync (fun () ->
             close_request_exports root Boundary_root_stopped)
       in
       let jobs = all_live_jobs root in
       let* () = request_job_cancellations jobs in
       let* () = await_job_settlement jobs |> widen_never in
       let+ result =
         Eta.Effect.sync (fun () ->
             let failure =
               Eta.Sync_lock.use root.lock @@ fun () -> Atomic.get root.failure
             in
             close root;
             match failure with
             | None -> Stop_settled
             | Some failure ->
                 Crash_settled
                   { Failure.failure; teardown_settled = true })
       in
       result)

  let settle_crash root =
    let open Eta.Syntax in
    Crux_telemetry.root_teardown
      (let* () =
         Eta.Effect.sync (fun () ->
             close_request_exports root Boundary_root_crashed)
       in
       let jobs = all_live_jobs root in
       let* () = request_job_cancellations jobs in
       let* () = await_job_settlement jobs |> widen_never in
       let+ settlement =
         Eta.Effect.sync (fun () ->
             let failure =
               Eta.Sync_lock.use root.lock @@ fun () ->
               match Atomic.get root.failure with
               | Some failure -> failure
               | None ->
                   invalid_arg
                     "Eta_crux: crash settlement lost its latched failure"
             in
             close root;
             { Failure.failure; teardown_settled = true })
       in
       Crash_settled settlement)

  type start_terminal = [ `Normal | `Stop | `Crash of Failure.t ]

  let terminal_locked root kind =
    (* A latched failure or stop request wins over the batch kind. A Crash
       batch without a latch settles as Stop: the old code re-read
       [root.failure] here, but it cannot change inside the section. *)
    match Atomic.get root.failure, Atomic.get root.stop_requested, kind with
    | Some failure, _, _ -> `Crash failure
    | None, true, _ | None, false, (Stop | Crash) -> `Stop
    | None, false, Normal -> `Normal

  let claim_and_terminal batch =
    let root = batch.root in
    Eta.Sync_lock.use root.lock @@ fun () ->
    if Atomic.get batch.started then Error Already_started
    else (
      Atomic.set batch.started true;
      Ok (terminal_locked root batch.kind))

  (* Empty batches have no works between the claim and admission, and the
     claim is one compare-and-set on [started], so the steady-state
     post-commit runs lock-free. The terminal reads are intentionally racy:
     a failure or stop landing just after the read settles on the next
     advance, which the phase gate already handles; Stop and Crash fall back
     to the settlement paths, which own their admission. *)
  let claim_terminal_admit batch =
    let root = batch.root in
    if not (Atomic.compare_and_set batch.started false true) then
      Error Already_started
    else (
      let terminal = terminal_locked root batch.kind in
      (match terminal with
      | `Normal ->
          if Atomic.get root.phase = Awaiting_post_commit then
            Atomic.set root.phase Ready
      | `Stop | `Crash _ -> ());
      Ok terminal)

  let admit (root : root_core) =
    Eta.Sync_lock.use root.lock @@ fun () ->
    if Atomic.get root.phase = Awaiting_post_commit then Atomic.set root.phase Ready;
    Admitted

  let start_normal (root : root_core) (batch : post_commit) =
    let open Eta.Syntax in
    if batch.works = [] && batch.cancellations = [] then
      Eta.Spi.Expert.sync1 root admit
    else
      let ordered_works = List.rev batch.works in
      let openings, programs =
        List.partition
          (fun work ->
            match work.payload with
            | Source_open _ -> true
            | Program _ -> false)
          ordered_works
      in
      let lifecycle, transitions =
        List.partition
          (fun work ->
            match work.trigger with
            | Failure.Transition_effect
            | Failure.Structural_reset
            | Failure.Poll_effect ->
                false
            | _ -> true)
          programs
      in
      let* () = request_job_cancellations batch.cancellations in
      let* () =
        match batch.cancellations with
        | [] -> Eta.Effect.unit
        | jobs ->
            Eta.Spi.daemon (await_job_settlement jobs) |> widen_never
      in
      let* source_programs = open_sources root openings |> widen_never in
      let terminal =
        Eta.Sync_lock.use root.lock @@ fun () ->
        match Atomic.get root.failure, Atomic.get root.stop_requested with
        | Some failure, _ -> `Crash failure
        | None, true -> `Stop
        | None, false -> `Continue
      in
      match terminal with
      | `Crash _ ->
          discard_observed_works batch.works;
          settle_crash root
      | `Stop ->
          discard_observed_works batch.works;
          settle_stop root
      | `Continue ->
          let* () =
            lifecycle @ source_programs
            |> List.map (fun work ->
                   start_owned_job root work |> widen_never)
            |> Eta.Effect.concat
          in
          let* () =
            transitions
            |> List.map (fun work ->
                   start_owned_job root work |> widen_never)
            |> Eta.Effect.concat
          in
          Eta.Spi.Expert.sync1 root admit

  let start (batch : post_commit) =
    let fallback batch terminal =
      match terminal with
      | `Normal -> start_normal batch.root batch
      | `Stop ->
          discard_observed_works batch.works;
          settle_stop batch.root
      | `Crash _ ->
          discard_observed_works batch.works;
          settle_crash batch.root
    in
    if batch.works = [] && batch.cancellations = [] then
      Eta.Spi.Expert.sync1_result_bind_value_direct batch claim_terminal_admit
        (function `Normal -> true | `Stop | `Crash _ -> false)
        (fun _batch _ -> Admitted)
        fallback
    else
      Eta.Spi.Expert.sync1_result_bind_value batch claim_and_terminal fallback
end

module Root = struct
  type t = {
    core : root_core;
    signal : signal_root;
    mutable committed_frame : frame option;
    projection : Projection.State.t;
  }

  type delivery_error =
    | Stale_endpoint
    | Stale_reset

  type advance_error =
    | Already_advancing
    | Awaiting_post_commit
    | Closed
    | Driver_attached

  type outcome =
    | Idle
    | Rejected of delivery_error
    | Committed of {
        commit : Projection.Commit.t;
        post_commit : Post_commit.t;
      }
    | Stopped of {
        post_commit : Post_commit.t;
      }
    | Failed of {
        failure : Failure.t;
        post_commit : Post_commit.t;
      }

  let create ?post_commit_effect_observer ~catalog ~projection_capacity
      ~ingress_capacity ~request_capacity description =
    if ingress_capacity <= 0 then
      invalid_arg "Eta_crux.Root.create: ingress_capacity must be positive";
    if request_capacity <= 0 then
      invalid_arg "Eta_crux.Root.create: request_capacity must be positive";
    let projection =
      Projection.State.create ~catalog ~capacity:projection_capacity
    in
    Option.iter Crux_testing.claim post_commit_effect_observer;
    let id = next_global "root identity" in
    let root_scope =
      {
        id = 0;
        parent = None;
        active = true;
        jobs = [];
        revokers = [];
      }
    in
    let core =
      {
        id;
        lock = Eta.Sync_lock.create ();
        ingress = Eta.Queue.bounded ~capacity:ingress_capacity ();
        wake = Eta.Queue.dropping ~capacity:1 ();
        wake_signaled = Atomic.make false;
        terminal_wake = Eta.Queue.dropping ~capacity:1 ();
        request_slots = Eta.Semaphore.make ~permits:request_capacity;
        ingress_capacity;
        request_capacity;
        phase = Atomic.make Ready;
        authority = Unstarted;
        start_pending = Atomic.make true;
        stop_requested = Atomic.make false;
        scopes = Int_map.singleton 0 root_scope;
        endpoints = Int_map.empty;
        boundary_exports = Int_map.empty;
        failure = Atomic.make None;
        failure_reported = Atomic.make false;
        next_scope = 1;
        next_endpoint = 0;
        next_position = 0L;
        bound_clock = None;
        last_clock_sample = None;
        current_clock_sample = None;
        clock_nodes = [];
        post_commit_effect_observer;
        dispose_signal = None;
        memo = Hashtbl.create 16;
        staging = create_staging ();
      }
    in
    let signal = create_signal_root core description in
    core.dispose_signal <- Some signal.sig_dispose_observer;
    { core; signal; committed_frame = None; projection }

  let set_projection_incarnation_for_test root next =
    Projection.State.set_next_incarnation_for_test root.projection next

  let request_stop (root : t) =
    let core = root.core in
    let close =
      Eta.Sync_lock.use core.lock @@ fun () ->
      if Atomic.get core.phase = Closed || Atomic.get core.stop_requested then false
      else (
        Atomic.set core.stop_requested true;
        Atomic.set core.start_pending false;
        true)
    in
    if close then (
      shutdown_ingress core;
      ignore (Eta.Queue.try_offer_now core.terminal_wake () : _))

  let make_batch (core : root_core) kind works cancellations =
    { root = core; kind; works; cancellations; started = Atomic.make false }

  let fail_from_exception_at (core : root_core) ~origin ~trigger exn =
    latch_exception core ~origin ~trigger exn;
    let failure =
      match Atomic.get core.failure with
      | Some failure -> failure
      | None -> assert false
    in
    Eta.Sync_lock.use core.lock @@ fun () ->
    Atomic.set core.failure_reported true;
    Atomic.set core.phase Awaiting_post_commit;
    Failed
      {
        failure;
        post_commit = make_batch core Crash [] [];
      }

  let fail_from_exception (core : root_core) trigger exn =
    fail_from_exception_at core ~origin:Failure.Transition ~trigger exn

  let fail_from_cause (core : root_core) trigger cause =
    let packed =
      Failure.Packed_cause.make ~pp_error:pp_staging_error cause
    in
    latch_failure_record core
      (failure_record core ~origin:Failure.Transition ~trigger packed);
    let failure =
      match Atomic.get core.failure with
      | Some failure -> failure
      | None -> assert false
    in
    Eta.Sync_lock.use core.lock @@ fun () ->
    Atomic.set core.failure_reported true;
    Atomic.set core.phase Awaiting_post_commit;
    Failed
      {
        failure;
        post_commit = make_batch core Crash [] [];
      }

  let fail_from_preflight (core : root_core) error =
    let packed =
      Failure.Packed_cause.make_projection_preflight error
    in
    latch_failure_record core
      (failure_record core ~origin:Failure.Transition
         ~trigger:Failure.Projection_preflight packed);
    let failure =
      match Atomic.get core.failure with
      | Some failure -> failure
      | None -> assert false
    in
    Eta.Sync_lock.use core.lock @@ fun () ->
    Atomic.set core.failure_reported true;
    Atomic.set core.phase Awaiting_post_commit;
    Failed
      {
        failure;
        post_commit = make_batch core Crash [] [];
      }

  (* Apply one candidate frame under the root lock. Mirrors the domain
     lifecycle of the old commit: close scopes whose branch left the frame
     (running their revokers and collecting their jobs), deactivate their
     endpoints, run freshly published commit hooks in order, activate new
     scopes and endpoints, append fresh revokers, and install machine state.
     Fresh records (works, endpoints, hooks, revokers) are detected by
     physical identity against the previously installed frame; scopes diff
     by scope id. Returns the works and job cancellations for the
     post-commit batch. *)
  let install_frame (core : root_core) ~previous ~(frame : frame) =
    let contribution = frame.contribution in
    let previous_contribution =
      match previous with
      | None -> contribution_empty
      | Some previous -> previous.contribution
    in
    if contribution_equal previous_contribution contribution then ([], [])
    else
    let works = contribution_items_to_list contribution.works in
    let previous_works =
      contribution_items_to_list previous_contribution.works
    in
    let commit_hooks =
      contribution_items_to_list contribution.commit_hooks
    in
    let previous_commit_hooks =
      contribution_items_to_list previous_contribution.commit_hooks
    in
    let added_revokers =
      contribution_items_to_list contribution.added_revokers
    in
    let previous_added_revokers =
      contribution_items_to_list previous_contribution.added_revokers
    in
    let added_scopes =
      contribution_items_to_list contribution.added_scopes
    in
    let previous_added_scopes =
      contribution_items_to_list previous_contribution.added_scopes
    in
    let endpoints =
      contribution_items_to_list contribution.endpoints
    in
    let fresh_works =
      List.filter
        (fun work -> not (List.memq work previous_works))
        works
    in
    let fresh_hooks =
      List.filter
        (fun hook ->
          not (List.memq hook previous_commit_hooks))
        commit_hooks
    in
    let fresh_revokers =
      List.filter
        (fun revoker ->
          not (List.memq revoker previous_added_revokers))
        added_revokers
    in
    let scopes_with_additions =
      List.fold_left
        (fun scopes (scope : scope_state) -> Int_map.add scope.id scope scopes)
        core.scopes added_scopes
    in
    let removed =
      List.fold_left
        (fun removed (scope : scope_state) ->
          if
            List.exists
              (fun (candidate : scope_state) -> candidate.id = scope.id)
              added_scopes
          then removed
          else Int_set.add scope.id removed)
        Int_set.empty previous_added_scopes
    in
    let is_removed scope =
      Int_set.exists
        (fun ancestor ->
          scope_is_descendant scopes_with_additions ~ancestor scope)
        removed
    in
    let removed_jobs =
      Int_map.fold
        (fun _ (scope : scope_state) jobs ->
          if is_removed scope.id then List.rev_append scope.jobs jobs
          else jobs)
        scopes_with_additions []
    in
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
      core.endpoints;
    List.iter (fun hook -> hook ()) fresh_hooks;
    List.iter
      (fun (scope : scope_state) ->
        if not (is_removed scope.id) then scope.active <- true)
      added_scopes;
    List.iter
      (fun (endpoint : endpoint_core) ->
        if not (is_removed endpoint.scope) then endpoint.active <- true)
      endpoints;
    List.iter
      (fun (scope_id, revoke) ->
        match Int_map.find_opt scope_id scopes_with_additions with
        | Some scope when not (is_removed scope_id) ->
            scope.revokers <- revoke :: scope.revokers
          | Some _ | None -> ())
      fresh_revokers;
    core.scopes <-
      Int_map.filter
        (fun _ (scope : scope_state) ->
          scope.active || not (is_removed scope.id))
        scopes_with_additions;
    Hashtbl.filter_map_inplace
      (fun (scope_id, _) packed ->
        if is_removed scope_id then None else Some packed)
      core.memo;
    let new_endpoints =
      List.filter
        (fun (endpoint : endpoint_core) ->
          not (Int_map.mem endpoint.id core.endpoints))
        endpoints
    in
    core.endpoints <-
      List.fold_left
        (fun endpoints (endpoint : endpoint_core) ->
          Int_map.add endpoint.id endpoint endpoints)
        (Int_map.filter
           (fun _ (endpoint : endpoint_core) -> endpoint.active)
           core.endpoints)
        new_endpoints;
    (fresh_works, removed_jobs)

  let observable_work (work : work) =
    match work.trigger with
    | Failure.Transition_effect
    | Failure.Structural_reset
    | Failure.Poll_effect ->
        true
    | Failure.Initial_start
    | Failure.Endpoint_action
    | Failure.Clock_sample
    | Failure.Clock_due
    | Failure.Lifecycle_program
    | Failure.Source_opening
    | Failure.Source_producer
    | Failure.Local_export_invocation
    | Failure.Serialized_export_invocation
    | Failure.Outbound_request
    | Failure.Inbound_response
    | Failure.Request_cancellation
    | Failure.Projection_preflight
    | Failure.Projection_delivery
    | Failure.Stop_teardown
    | Failure.Crash_teardown
    | Failure.Application_crash_handler ->
        false

  let record_staged_effects (core : root_core) works =
    match core.post_commit_effect_observer with
    | None -> ()
    | Some observer ->
        let observable = List.filter observable_work works in
        let observations =
          Crux_testing.stage observer (List.length observable)
        in
        List.iter2
          (fun work observation ->
            work.observation <- Some observation)
          observable observations

  let commit (core : root_core) root ~staging ~trigger =
    let open Eta.Syntax in
    let staged_sets =
      match staging.model_sets with
      | [] | [ _ ] -> staging.model_sets
      | _ -> List.rev staging.model_sets
    in
    let apply_model_sets =
      let apply_set set_thunk =
        match set_thunk () with
        | Ok () -> Eta.Effect.unit
        | Error err -> Eta.Effect.fail (err :> staging_error)
      in
      match staged_sets with
      | [] -> Eta.Effect.unit
      | [set_thunk] ->
          apply_set set_thunk
      | set_thunks ->
          set_thunks
          |> List.map apply_set
          |> Eta.Effect.concat
    in
    let before_read =
      if apply_model_sets == Eta.Effect.unit then
        Eta.Effect.seq root.signal.sig_stabilize
          root.signal.sig_ensure_observer
      else
        Eta.Spi.Expert.seq3 root.signal.sig_ensure_observer apply_model_sets
          root.signal.sig_stabilize
    in
    let graph_step =
      Eta.Spi.Expert.then_ root.signal.sig_read_frame before_read
    in
    Eta.Spi.Expert.to_exit_bind_ok4_sync core root staging trigger
      (fun step_exit core root staging trigger ->
        match step_exit with
        | Eta.Exit.Error cause ->
            List.iter (fun undo -> undo ()) staging.undos;
            Ok (fail_from_cause core trigger cause)
        | Eta.Exit.Ok frame ->
            let prepared =
              try
                match
                  Projection.State.prepare root.projection
                    (contribution_items_to_list
                       frame.contribution.projections)
                with
                | Ok prepared -> `Prepared prepared
                | Error error -> `Preflight error
              with exn -> `Raised exn
            in
            (match prepared with
            | `Preflight error ->
                List.iter (fun undo -> undo ()) staging.undos;
                Ok (fail_from_preflight core error)
            | `Raised exn ->
                List.iter (fun undo -> undo ()) staging.undos;
                Ok
                  (fail_from_exception core
                     Failure.Projection_preflight exn)
            | `Prepared prepared -> (
                match
                  Eta.Sync_lock.use core.lock @@ fun () ->
                  match Atomic.get core.failure with
                  | Some failure -> Either.Left failure
                  | None ->
                      let works, cancellations =
                        install_frame core
                          ~previous:root.committed_frame ~frame
                      in
                      let works =
                        List.rev_append (List.rev staging.works)
                          works
                      in
                      root.committed_frame <- Some frame;
                      Projection.State.install root.projection prepared;
                      record_staged_effects core works;
                      Atomic.set core.phase Awaiting_post_commit;
                      Either.Right
                        (Committed
                           {
                             commit =
                               Projection.State.commit prepared;
                             post_commit =
                               make_batch core Normal works
                                 cancellations;
                           })
                with
                | Either.Right committed -> Ok committed
                | Either.Left failure ->
                    List.iter (fun undo -> undo ()) staging.undos;
                    Ok
                      (Eta.Sync_lock.use core.lock @@ fun () ->
                       Atomic.set core.failure_reported true;
                       Atomic.set core.phase Awaiting_post_commit;
                       Failed
                         {
                           failure;
                           post_commit =
                             make_batch core Crash [] [];
                         }))))
      graph_step

  (* Lock-free phase gate: the [Ready -> Advancing] claim is one CAS, so the
     steady-state advance pays no critical section here. Terminal reads after
     the claim are intentionally racy: a failure latched just after the claim
     is caught by [commit]'s merged latch-check section, and a stop requested
     just after the claim settles through the post-commit terminal decision -
     exactly the outcomes the locked gate produced when the same events
     landed immediately after its section. Both are top-level functions so
     the steady-state advance allocates no gate closures. *)
  let terminal_claimed (core : root_core) =
    (* [terminal_event] with the phase already claimed. *)
    match Atomic.get core.failure with
    | Some failure ->
        if Atomic.get core.failure_reported then (
          Atomic.set core.phase Closed;
          Ok `Closed_after_crash)
        else (
          Atomic.set core.failure_reported true;
          Ok (`Crash failure))
    | None ->
        if Atomic.get core.stop_requested then Ok `Stop
        else if Atomic.get core.start_pending then (
          Atomic.set core.start_pending false;
          Ok `Start)
        else Ok `None

  let rec begin_advance_gate (core : root_core) () =
    match Atomic.get core.phase with
    | Ready ->
        if Atomic.compare_and_set core.phase Ready Advancing then
          terminal_claimed core
        else begin_advance_gate core ()
    | Advancing -> Error Already_advancing
    | Awaiting_post_commit -> Error Awaiting_post_commit
    | Closed -> Error Closed

  let begin_advance_and_terminal (core : root_core) =
    begin_advance_gate core ()

  let reset_ready (core : root_core) =
    Eta.Sync_lock.use core.lock @@ fun () ->
    if Atomic.get core.phase = Advancing then Atomic.set core.phase Ready

  type clock_accept_error =
    | Clock_runtime_mismatch
    | Clock_moved_backward

  let read_active_clock =
    Eta.Spi.Expert.make ~leaf_name:"eta_crux.clock_sample"
      (fun context ->
        let clock = Eta.Spi.Expert.Clock.current context in
        let result =
          try Ok { sample_clock = clock; sample_ms = Eta.Spi.Expert.Clock.now_ms clock }
          with exn -> Error exn
        in
        Eta.Exit.Ok result)

  let accept_clock_sample (core : root_core) sample =
    Eta.Sync_lock.use core.lock @@ fun () ->
    match core.bound_clock with
    | Some clock
      when not
             (Eta.Spi.Expert.Clock.same clock sample.sample_clock) ->
        Error Clock_runtime_mismatch
    | None ->
        core.bound_clock <- Some sample.sample_clock;
        core.last_clock_sample <- Some sample.sample_ms;
        Ok ()
    | Some _ -> (
        match core.last_clock_sample with
        | Some previous when sample.sample_ms < previous ->
            Error Clock_moved_backward
        | Some _ | None ->
            core.last_clock_sample <- Some sample.sample_ms;
            Ok ())

  let active_clock_nodes (core : root_core) =
    List.filter
      (fun node -> scope_live core node.clock_scope)
      core.clock_nodes

  let earliest_deadline (core : root_core) =
    active_clock_nodes core
    |> List.fold_left
         (fun earliest node ->
           match earliest, node.clock_deadline () with
           | None, deadline -> deadline
           | earliest, None -> earliest
           | Some left, Some right -> Some (min left right))
         None

  let sample_clock_nodes (core : root_core) sample =
    let rec loop = function
      | [] -> Ok ()
      | node :: rest -> (
          try
            match node.clock_sample sample with
            | Ok () -> loop rest
            | Error error -> Error (`Staging error)
          with
          | Runtime_mismatch -> Error `Runtime_mismatch
          | Clock_regression -> Error `Clock_regression
          | Deadline_overflow -> Error (`Raised Deadline_overflow)
          | Past_dynamic_deadline ->
              Error (`Raised Past_dynamic_deadline)
          | exn -> Error (`Raised exn))
    in
    loop (active_clock_nodes core)

  let clear_current_clock_sample (core : root_core) =
    Eta.Effect.sync (fun () -> core.current_clock_sample <- None)

  let fail_clock (core : root_core) exn =
    fail_from_exception_at core ~origin:Failure.Graph_clock
      ~trigger:Failure.Clock_sample exn

  let accept_or_fail_clock core sample =
    match accept_clock_sample core sample with
    | Ok () -> Ok sample
    | Error Clock_runtime_mismatch ->
        Error (fail_clock core Runtime_mismatch)
    | Error Clock_moved_backward ->
        Error (fail_clock core Clock_regression)

  let claim_direct_authority (core : root_core) =
    Eta.Sync_lock.use core.lock @@ fun () ->
    match core.authority with
    | Unstarted ->
        core.authority <- Direct_started;
        Ok ()
    | Direct_started -> Ok ()
    | Driver_owned -> Error Driver_attached

  let claim_driver_authority (core : root_core) =
    Eta.Sync_lock.use core.lock @@ fun () ->
    match core.authority with
    | Unstarted
      when Atomic.get core.start_pending
           && not (Atomic.get core.stop_requested)
           && Option.is_none (Atomic.get core.failure)
           && Atomic.get core.phase = Ready ->
        core.authority <- Driver_owned;
        Ok ()
    | Unstarted -> Error `Root_already_started
    | Direct_started -> Error `Root_already_started
    | Driver_owned -> Error `Already_attached

  let with_clock_sample core ~trigger sample effect =
    core.current_clock_sample <- Some sample;
    match sample_clock_nodes core sample with
    | Error `Runtime_mismatch ->
        core.current_clock_sample <- None;
        Eta.Effect.sync (fun () ->
            Ok (fail_clock core Runtime_mismatch))
    | Error `Clock_regression ->
        core.current_clock_sample <- None;
        Eta.Effect.sync (fun () ->
            Ok (fail_clock core Clock_regression))
    | Error (`Raised exn) ->
        core.current_clock_sample <- None;
        Eta.Effect.sync (fun () ->
            Ok (fail_from_exception core trigger exn))
    | Error (`Staging error) ->
        core.current_clock_sample <- None;
        Eta.Effect.sync (fun () ->
            Ok
              (fail_from_cause core trigger
                 (Eta.Cause.fail error)))
    | Ok () ->
        Eta.Effect.finally (clear_current_clock_sample core) effect

  let advance_with_authority ~driver root =
    let core = root.core in
    let staging = core.staging in
    staging.model_sets <- [];
    staging.undos <- [];
    staging.works <- [];
    staging.message_owner <- None;
    let authority =
      if driver then Ok () else claim_direct_authority core
    in
    match authority with
    | Error error -> Eta.Effect.sync (fun () -> Error error)
    | Ok () -> (
    match begin_advance_and_terminal core with
    | Error _ as error -> Eta.Effect.sync (fun () -> error)
    | Ok (`Crash failure) ->
        Eta.Effect.sync (fun () ->
            Eta.Sync_lock.use core.lock @@ fun () ->
            Atomic.set core.phase Awaiting_post_commit;
            Ok
              (Failed
                 {
                   failure;
                   post_commit = make_batch core Crash [] [];
                 }))
    | Ok `Closed_after_crash ->
        Eta.Effect.sync (fun () ->
            Eta.Sync_lock.use core.lock @@ fun () -> Atomic.set core.phase Closed;
            Error Closed)
    | Ok `Stop ->
        Eta.Effect.sync (fun () ->
            Eta.Sync_lock.use core.lock @@ fun () ->
            Atomic.set core.phase Awaiting_post_commit;
            Ok (Stopped { post_commit = make_batch core Stop [] [] }))
    | Ok `Start ->
        Eta.Effect.bind (fun read ->
        (match read with
        | Error exn ->
            Eta.Effect.sync (fun () ->
                Ok (fail_clock core exn))
        | Ok sample -> (
            match accept_or_fail_clock core sample with
            | Error failed -> Eta.Effect.sync (fun () -> Ok failed)
            | Ok sample ->
                with_clock_sample core
                  ~trigger:Failure.Initial_start sample
                  (commit core root ~staging
                     ~trigger:Failure.Initial_start))))
          read_active_clock
    | Ok `None ->
        let process_message sample = function
        | Message { endpoint; action; owner_scope } ->
          if
            (not endpoint.active)
            || endpoint.root != core
            || not (scope_live core endpoint.scope)
            || endpoint.generation <> endpoint.id
          then (
            reset_ready core;
            Eta.Effect.sync (fun () ->
                Ok (Rejected Stale_endpoint)))
          else (
            staging.message_owner <- owner_scope;
            let dispatched =
              try
                endpoint.dispatch staging action;
                `Dispatched
              with
              | Failure_already_latched -> `Latched
              | exn -> `Raised exn
            in
            match dispatched with
            | `Dispatched ->
                with_clock_sample core
                  ~trigger:Failure.Endpoint_action sample
                  (commit core root ~staging
                     ~trigger:Failure.Endpoint_action)
            | `Latched ->
                Eta.Effect.sync (fun () ->
                    List.iter (fun undo -> undo ()) staging.undos;
                    let failure =
                      match Atomic.get core.failure with
                      | Some failure -> failure
                      | None ->
                          invalid_arg
                            "Eta_crux: latched transition failure was not recorded"
                    in
                    Eta.Sync_lock.use core.lock @@ fun () ->
                    Atomic.set core.failure_reported true;
                    Atomic.set core.phase Awaiting_post_commit;
                    Ok
                      (Failed
                         {
                           failure;
                           post_commit =
                             make_batch core Crash [] [];
                         }))
            | `Raised exn ->
                Eta.Effect.sync (fun () ->
                    List.iter (fun undo -> undo ()) staging.undos;
                    Ok
                      (fail_from_exception core
                         Failure.Endpoint_action exn)))
        | Reset_message reset ->
            if
              reset.reset_root != core
              || not (scope_live core reset.reset_scope)
            then (
              reset_ready core;
              Eta.Effect.sync (fun () ->
                  Ok (Rejected Stale_reset)))
            else
              let descendants =
                Int_map.fold
                  (fun _ endpoint descendants ->
                    if
                      endpoint.active
                      && scope_live core endpoint.scope
                      && scope_is_descendant core.scopes
                           ~ancestor:reset.reset_scope endpoint.scope
                    then endpoint :: descendants
                    else descendants)
                  core.endpoints []
              in
              let reset_result =
                try
                  List.iter
                    (fun (endpoint : endpoint_core) ->
                      Option.iter
                        (fun reset -> reset staging)
                        endpoint.reset)
                    descendants;
                  `Reset
                with
                | Failure_already_latched -> `Latched
                | exn -> `Raised exn
              in
              (match reset_result with
              | `Reset ->
                  with_clock_sample core
                    ~trigger:Failure.Structural_reset sample
                    (commit core root ~staging
                       ~trigger:Failure.Structural_reset)
              | `Latched ->
                  Eta.Effect.sync (fun () ->
                      List.iter (fun undo -> undo ()) staging.undos;
                      let failure =
                        match Atomic.get core.failure with
                        | Some failure -> failure
                        | None ->
                            invalid_arg
                              "Eta_crux: latched reset failure was not recorded"
                      in
                      Eta.Sync_lock.use core.lock @@ fun () ->
                      Atomic.set core.failure_reported true;
                      Atomic.set core.phase Awaiting_post_commit;
                      Ok
                        (Failed
                           {
                             failure;
                             post_commit =
                               make_batch core Crash [] [];
                           }))
              | `Raised exn ->
                  Eta.Effect.sync (fun () ->
                      List.iter (fun undo -> undo ()) staging.undos;
                      Ok
                        (fail_from_exception core
                           Failure.Structural_reset exn)))
        in
        let poll_with_sample sample =
          let due =
            match earliest_deadline core with
            | Some deadline -> sample.sample_ms >= deadline
            | None -> false
          in
          if due then
            with_clock_sample core ~trigger:Failure.Clock_due
              sample
              (commit core root ~staging
                 ~trigger:Failure.Clock_due)
          else
          match Eta.Queue.poll_now core.ingress with
          | `Empty | `Closed ->
              reset_ready core;
              Eta.Effect.sync (fun () -> Ok Idle)
          | `Closed_with_error (_ : never) -> .
          | `Item message -> process_message sample message
        in
        Eta.Effect.bind (fun read ->
        (match read with
        | Error exn ->
            Eta.Effect.sync (fun () -> Ok (fail_clock core exn))
        | Ok sample -> (
            match accept_or_fail_clock core sample with
            | Error failed -> Eta.Effect.sync (fun () -> Ok failed)
            | Ok sample -> poll_with_sample sample)))
          read_active_clock)

  let advance root = advance_with_authority ~driver:false root
  let advance_driver root = advance_with_authority ~driver:true root
  let attach_driver root = claim_driver_authority root.core
  let earliest_deadline root = earliest_deadline root.core
  let bound_clock root = root.core.bound_clock

  let sleep_until_deadline root deadline =
    let core = root.core in
    Eta.Spi.Expert.make ~leaf_name:"eta_crux.driver_deadline_sleep"
      (fun context ->
        let active = Eta.Spi.Expert.Clock.current context in
        let sample =
          try
            Ok
              {
                sample_clock = active;
                sample_ms = Eta.Spi.Expert.Clock.now_ms active;
              }
          with exn -> Error exn
        in
        (match sample with
        | Error exn ->
            ignore (fail_clock core exn : outcome)
        | Ok sample -> (
            match accept_clock_sample core sample with
            | Error Clock_runtime_mismatch ->
                ignore
                  (fail_clock core Runtime_mismatch : outcome)
            | Error Clock_moved_backward ->
                ignore
                  (fail_clock core Clock_regression : outcome)
            | Ok () ->
                if sample.sample_ms < deadline then
                  Eta.Spi.Expert.Clock.sleep active
                    (Eta.Duration.ms
                       (deadline - sample.sample_ms))));
        Eta.Exit.Ok ())
end
