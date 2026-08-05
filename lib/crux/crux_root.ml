open Crux_engine

module Failure = Crux_failure.Failure

type post_kind =
  | Normal
  | Stop
  | Crash

type post_commit = {
  root : root_core;
  kind : post_kind;
  works : work list;
  cancellations : owned_job list;
  mutable started : bool;
  lock : Eta.Sync_lock.t;
}

let work_failure_effect (root : root_core) (work : work) =
  let open Eta.Syntax in
  let effect =
    match work.payload with
    | Program effect -> effect
    | Source_open _ ->
        invalid_arg "Eta_crux: source opening admitted as a running program"
  in
  let* exit = Eta.Effect.to_exit effect in
  match exit with
  | Eta.Exit.Ok () -> Eta.Effect.unit
  | Eta.Exit.Error cause when Eta.Cause.is_interrupt_only cause ->
      Eta.Effect.unit
  | Eta.Exit.Error cause ->
      Eta.Effect.sync (fun () ->
          let origin, trigger =
            Eta.Sync_lock.use root.lock @@ fun () ->
            if root.stop_requested then
              (Failure.Cleanup, Failure.Stop_teardown)
            else
              match root.failure with
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
      Eta.Spi.daemon
        (with_owned_context root work.scope
           (run_owned_job root work job))
  | None -> Eta.Effect.unit

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

let widen_never effect = Eta.Effect.map_error absurd effect

let open_sources (root : root_core) works =
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
                      (fun effect ->
                        {
                          work with
                          trigger = Failure.Source_producer;
                          payload = Program effect;
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

  let claim batch =
    Eta.Sync_lock.use batch.lock @@ fun () ->
    if batch.started then Error Already_started
    else (
      batch.started <- true;
      Ok ())

  let close (root : root_core) =
    Eta.Sync_lock.use root.lock @@ fun () -> root.phase <- Closed

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
               Eta.Sync_lock.use root.lock @@ fun () -> root.failure
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
               match root.failure with
               | Some failure -> failure
               | None ->
                   invalid_arg
                     "Eta_crux: crash settlement lost its latched failure"
             in
             close root;
             { Failure.failure; teardown_settled = true })
       in
       Crash_settled settlement)

  let start batch =
    let open Eta.Syntax in
    let* () = Eta.Effect.sync_result (fun () -> claim batch) in
    let root = batch.root in
    let terminal =
      Eta.Sync_lock.use root.lock @@ fun () ->
      match root.failure, root.stop_requested, batch.kind with
      | Some failure, _, _ -> `Crash failure
      | None, true, _ | None, false, Stop -> `Stop
      | None, false, Crash -> (
          match root.failure with
          | Some failure -> `Crash failure
          | None -> `Stop)
      | None, false, Normal -> `Normal
    in
    match terminal with
    | `Normal ->
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
            (fun work -> work.trigger <> Failure.Transition_effect)
            programs
        in
        let* () =
          request_job_cancellations batch.cancellations
        in
        
        let* () =
          (match batch.cancellations with
          | [] -> Eta.Effect.unit
          | jobs ->
              Eta.Spi.daemon (await_job_settlement jobs)
              |> widen_never)
        in
        let* source_programs = open_sources root openings |> widen_never in
        let terminal =
          Eta.Sync_lock.use root.lock @@ fun () ->
          match root.failure, root.stop_requested with
          | Some failure, _ -> `Crash failure
          | None, true -> `Stop
          | None, false -> `Continue
        in
        (match terminal with
        | `Crash _ -> settle_crash root
        | `Stop -> settle_stop root
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
            let+ () =
              Eta.Effect.sync (fun () ->
                  Eta.Sync_lock.use root.lock @@ fun () ->
                  if root.phase = Awaiting_post_commit then
                    root.phase <- Ready)
            in
            Admitted)
    | `Stop -> settle_stop root
    | `Crash _ -> settle_crash root
end

module Root = struct
  type 'output description = 'output t

  type 'output t = {
    core : root_core;
    description : 'output description;
    signal : 'output signal_root;
    mutable committed_frame : 'output frame option;
  }

  type delivery_error = Stale_endpoint

  type advance_error =
    | Already_advancing
    | Awaiting_post_commit
    | Closed

  type 'output outcome =
    | Idle
    | Rejected of delivery_error
    | Committed of {
        output : 'output;
        post_commit : Post_commit.t;
      }
    | Stopped of {
        post_commit : Post_commit.t;
      }
    | Failed of {
        failure : Failure.t;
        post_commit : Post_commit.t;
      }

  let create ~ingress_capacity ~request_capacity description =
    if ingress_capacity <= 0 then
      invalid_arg "Eta_crux.Root.create: ingress_capacity must be positive";
    if request_capacity <= 0 then
      invalid_arg "Eta_crux.Root.create: request_capacity must be positive";
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
        terminal_wake = Eta.Queue.dropping ~capacity:1 ();
        request_slots = Eta.Semaphore.make ~permits:request_capacity;
        ingress_capacity;
        request_capacity;
        phase = Ready;
        start_pending = true;
        stop_requested = false;
        scopes = Int_map.singleton 0 root_scope;
        endpoints = Int_map.empty;
        boundary_exports = Int_map.empty;
        failure = None;
        failure_reported = false;
        next_scope = 1;
        next_endpoint = 0;
        next_position = 0L;
        dispose_signal = None;
        memo = Hashtbl.create 16;
      }
    in
    let signal = create_signal_root core description in
    core.dispose_signal <- Some signal.sig_dispose_observer;
    { core; description; signal; committed_frame = None }

  let request_stop (root : 'output t) =
    let core = root.core in
    let close =
      Eta.Sync_lock.use core.lock @@ fun () ->
      if core.phase = Closed || core.stop_requested then false
      else (
        core.stop_requested <- true;
        core.start_pending <- false;
        true)
    in
    if close then (
      shutdown_ingress core;
      ignore (Eta.Queue.try_offer_now core.terminal_wake () : _))

  let terminal_event (core : root_core) =
    Eta.Sync_lock.use core.lock @@ fun () ->
    match core.failure with
    | Some failure ->
        if core.failure_reported then (
          core.phase <- Closed;
          Some `Closed_after_crash)
        else (
          core.failure_reported <- true;
          Some (`Crash failure))
    | None ->
        if core.stop_requested then Some `Stop
        else if core.start_pending then (
          core.start_pending <- false;
          Some `Start)
        else None

  let make_batch (core : root_core) kind works cancellations =
    {
      root = core;
      kind;
      works;
      cancellations;
      started = false;
      lock = Eta.Sync_lock.create ();
    }

  let fail_from_exception (core : root_core) trigger exn =
    latch_exception core ~origin:Failure.Transition ~trigger exn;
    let failure =
      match core.failure with
      | Some failure -> failure
      | None -> assert false
    in
    Eta.Sync_lock.use core.lock @@ fun () ->
    core.failure_reported <- true;
    core.phase <- Awaiting_post_commit;
    Failed
      {
        failure;
        post_commit = make_batch core Crash [] [];
      }

  let fail_from_cause (core : root_core) trigger cause =
    let packed =
      Failure.Packed_cause.make ~pp_error:pp_staging_error cause
    in
    latch_failure_record core
      (failure_record core ~origin:Failure.Transition ~trigger packed);
    let failure =
      match core.failure with
      | Some failure -> failure
      | None -> assert false
    in
    Eta.Sync_lock.use core.lock @@ fun () ->
    core.failure_reported <- true;
    core.phase <- Awaiting_post_commit;
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
  let install_frame (core : root_core) ~previous ~(frame : 'output frame) =
    let contribution = frame.contribution in
    let previous_contribution =
      match previous with
      | None -> contribution_empty
      | Some (previous : 'output frame) -> previous.contribution
    in
    let fresh_works =
      List.filter
        (fun work -> not (List.memq work previous_contribution.works))
        contribution.works
    in
    let fresh_hooks =
      List.filter
        (fun hook ->
          not (List.memq hook previous_contribution.commit_hooks))
        contribution.commit_hooks
    in
    let fresh_revokers =
      List.filter
        (fun revoker ->
          not (List.memq revoker previous_contribution.added_revokers))
        contribution.added_revokers
    in
    let scopes_with_additions =
      List.fold_left
        (fun scopes (scope : scope_state) -> Int_map.add scope.id scope scopes)
        core.scopes contribution.added_scopes
    in
    let removed =
      List.fold_left
        (fun removed (scope : scope_state) ->
          if
            List.exists
              (fun (candidate : scope_state) -> candidate.id = scope.id)
              contribution.added_scopes
          then removed
          else Int_set.add scope.id removed)
        Int_set.empty previous_contribution.added_scopes
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
      contribution.added_scopes;
    List.iter
      (fun (endpoint : endpoint_core) ->
        if not (is_removed endpoint.scope) then endpoint.active <- true)
      contribution.endpoints;
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
        contribution.endpoints
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

  let commit (core : root_core) root ~staging ~trigger =
    let open Eta.Syntax in
    let staged_sets = List.rev staging.model_sets in
    let graph_step =
      let* () = root.signal.sig_ensure_observer in
      let* () =
        staged_sets
        |> List.map (fun set_effect ->
               Eta.Effect.map_error
                 (fun err -> (err :> staging_error))
                 set_effect)
        |> Eta.Effect.concat
      in
      let* () = root.signal.sig_stabilize in
      root.signal.sig_read_frame ()
    in
    let* step_exit = Eta.Effect.to_exit graph_step in
    match step_exit with
    | Eta.Exit.Error cause ->
        Eta.Effect.sync (fun () ->
            List.iter (fun undo -> undo ()) staging.undos)
        |> Eta.Effect.map (fun () -> fail_from_cause core trigger cause)
    | Eta.Exit.Ok frame -> (
        (* A failure latched during staging or stabilization wins over the
           candidate frame: roll back and report instead of installing. *)
        let fatal_won =
          Eta.Sync_lock.use core.lock @@ fun () -> core.failure
        in
        match fatal_won with
        | Some failure ->
            Eta.Effect.sync (fun () ->
                List.iter (fun undo -> undo ()) staging.undos;
                Eta.Sync_lock.use core.lock @@ fun () ->
                core.failure_reported <- true;
                core.phase <- Awaiting_post_commit;
                Failed
                  {
                    failure;
                    post_commit = make_batch core Crash [] [];
                  })
        | None ->
            Eta.Effect.sync (fun () ->
                Eta.Sync_lock.use core.lock @@ fun () ->
                let works, cancellations =
                  install_frame core ~previous:root.committed_frame ~frame
                in
            let works = List.rev_append (List.rev staging.works) works in
                root.committed_frame <- Some frame;
                core.phase <- Awaiting_post_commit;
                Committed
                  {
                    output = frame.output;
                    post_commit = make_batch core Normal works cancellations;
                  }))

  let begin_advance (core : root_core) =
    Eta.Sync_lock.use core.lock @@ fun () ->
    match core.phase with
    | Ready ->
        core.phase <- Advancing;
        Ok ()
    | Advancing -> Error Already_advancing
    | Awaiting_post_commit -> Error Awaiting_post_commit
    | Closed -> Error Closed

  let reset_ready (core : root_core) =
    Eta.Sync_lock.use core.lock @@ fun () ->
    if core.phase = Advancing then core.phase <- Ready

  let advance root =
    let core = root.core in
    match begin_advance core with
    | Error _ as error -> Eta.Effect.sync (fun () -> error)
    | Ok () -> (
        let event = terminal_event core in
        match event with
        | Some (`Crash failure) ->
            Eta.Effect.sync (fun () ->
                Eta.Sync_lock.use core.lock @@ fun () ->
                core.phase <- Awaiting_post_commit;
                Ok
                  (Failed
                     {
                       failure;
                       post_commit = make_batch core Crash [] [];
                     }))
        | Some `Closed_after_crash ->
            Eta.Effect.sync (fun () ->
                Eta.Sync_lock.use core.lock @@ fun () -> core.phase <- Closed;
                Error Closed)
        | Some `Stop ->
            Eta.Effect.sync (fun () ->
                Eta.Sync_lock.use core.lock @@ fun () ->
                core.phase <- Awaiting_post_commit;
                Ok (Stopped { post_commit = make_batch core Stop [] [] }))
        | Some `Start ->
            let staging = create_staging () in
            commit core root ~staging ~trigger:Failure.Initial_start
            |> Eta.Effect.map (fun outcome -> Ok outcome)
        | None -> (
            match Eta.Queue.poll_now core.ingress with
            | `Empty ->
                reset_ready core;
                Eta.Effect.sync (fun () -> Ok Idle)
            | `Closed ->
                reset_ready core;
                Eta.Effect.sync (fun () -> Ok Idle)
            | `Closed_with_error (_ : never) -> .
            | `Item (Message { endpoint; action; owner_scope }) ->
                if
                  (not endpoint.active)
                  || endpoint.root != core
                  || not (scope_live core endpoint.scope)
                  || endpoint.generation <> endpoint.id
                then (
                  reset_ready core;
                  Eta.Effect.sync (fun () -> Ok (Rejected Stale_endpoint)))
                else
                  let staging = create_staging () in
                  staging.message_owner <- owner_scope;
                  let dispatched =
                    try
                      endpoint.dispatch staging action;
                      `Dispatched
                    with
                    | Failure_already_latched -> `Latched
                    | exn -> `Raised exn
                  in
                  (match dispatched with
                  | `Dispatched ->
                      commit core root ~staging
                        ~trigger:Failure.Endpoint_message
                      |> Eta.Effect.map (fun outcome -> Ok outcome)
                  | `Latched ->
                      Eta.Effect.sync (fun () ->
                          List.iter (fun undo -> undo ()) staging.undos;
                          let failure =
                            match core.failure with
                            | Some failure -> failure
                            | None ->
                                invalid_arg
                                  "Eta_crux: latched transition failure was                                    not recorded"
                          in
                          Eta.Sync_lock.use core.lock @@ fun () ->
                          core.failure_reported <- true;
                          core.phase <- Awaiting_post_commit;
                          Ok
                            (Failed
                               {
                                 failure;
                                 post_commit = make_batch core Crash [] [];
                               }))
                  | `Raised exn ->
                      Eta.Effect.sync (fun () ->
                          List.iter (fun undo -> undo ()) staging.undos;
                          Ok (fail_from_exception core Failure.Endpoint_message exn)))))
end
