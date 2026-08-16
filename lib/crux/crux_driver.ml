open Crux_engine
open Crux_boundary
open Crux_driver_base

module Failure = Crux_failure.Failure
module Host_operation = Crux_boundary.Host_operation
module Request = Crux_boundary.Request
module Requester = Crux_boundary.Requester
module Wire = Crux_wire.Wire
module Serialized_session = Crux_wire.Serialized_session
module Root = Crux_root.Root
module Post_commit = Crux_root.Post_commit
module Projection = Crux_projection
module Remote_registry = Crux_remote_registry
module Serialized_dispatch = Crux_driver_serialized

module Driver = struct
  type binding = Crux_driver_base.binding
  type t = Crux_driver_base.t

  type terminal = Crux_driver_base.terminal =
    | Stopped
    | Crashed of Failure.settlement

  type reason = Crux_driver_base.reason =
    | Advancement
    | Session_replacement

  module Binding = struct
    type t = binding

    let identity operations =
      {
        core = make_binding operations;
        mode = Identity;
        replace =
          (fun _ ->
            Eta.Effect.fail Serialized_session.Closed);
      }

    let serialized ~operations ~session =
      if not (Serialized_session.claim session) then
        invalid_arg "Eta_crux.Driver.Binding.serialized: candidate already claimed";
      let authentication_key =
        Remote_registry.random_authentication_key ()
      in
      let binding =
        {
          core = make_binding operations;
          mode =
            Serialized
              {
                candidate = session;
                replacement_pending = false;
                replacement_installing = false;
                incoming_claimed = false;
                authentication_key;
                next_session = 1L;
                registry =
                  Remote_registry.create ~session:0L
                    ~authentication_key;
                registry_lock = Eta.Sync_lock.create ();
                closure_observed = false;
              };
          replace =
            (fun _ ->
              Eta.Effect.fail Serialized_session.Starting);
        }
      in
      let admin =
        {
          Serialized_session.replace_candidate =
            (fun candidate -> binding.replace candidate);
        }
      in
      (binding, admin)

    let requester binding operation =
      let operation_name = Host_operation.name operation in
      match Hashtbl.find_opt binding.core.operations operation_name with
      | Some (Host_operation.Pack registered)
        when Host_operation.same registered operation ->
          { Requester.binding = binding.core; operation }
      | Some _ ->
          invalid_arg
            "Eta_crux.Driver.Binding.requester: operation descriptor mismatch"
      | None ->
          invalid_arg
            ("Eta_crux.Driver.Binding.requester: unregistered operation "
           ^ operation_name)
  end

  module Delivery = Crux_driver_base.Delivery

  type event = Crux_driver_base.event =
    | Deliver of Delivery.t
    | Request of Request.Driver_event.t
    | Rejected of Root.delivery_error
    | Crash_detected of Failure.t
    | Closed of terminal

  let attachment_lock = Eta.Sync_lock.create ()

  let terminal_of_start_result driver = function
    | Post_commit.Admitted ->
        set_state driver Running;
        None
    | Post_commit.Stop_settled ->
        set_state driver Stopped_closed_pending;
        Some Stopped
    | Post_commit.Crash_settled settlement ->
        set_state driver (Crash_settled_pending settlement);
        Some (Crashed settlement)

  let start_post_commit driver post_commit =
    let open Eta.Syntax in
    let* result =
      Post_commit.start post_commit
      |> Eta.Effect.or_die (fun Post_commit.Already_started ->
             Invalid_argument
               "Eta_crux.Driver: post-commit token was already started")
      |> Crux_telemetry.post_commit
    in
    let terminal = terminal_of_start_result driver result in
    Eta.Effect.pure terminal

  let create_delivery driver ~initial ~reason projection post_commit =
    let delivery_lock = Eta.Sync_lock.create () in
    let completed = ref false in
    let claim () =
      Eta.Sync_lock.use delivery_lock @@ fun () ->
      if !completed then false
      else (
        completed := true;
        true)
    in
    let answer answer =
      let body =
        if not (claim ()) then
          Eta.Effect.pure (Error Already_completed)
        else
          match answer with
          | `Delivered ->
              let open Eta.Syntax in
              let* terminal =
                start_post_commit driver post_commit
              in
              let* () =
                if initial && Option.is_none terminal then
                  Crux_telemetry.root_started ()
                else Eta.Effect.unit
              in
              wake driver;
              Eta.Effect.pure (Ok ())
          | `Failed cause ->
              Eta.Effect.sync (fun () ->
                  latch_failure_record driver.root.core
                    (failure_record driver.root.core
                       ~origin:Failure.Adapter_delivery
                       ~trigger:Failure.Projection_delivery cause);
                  let failure =
                    Eta.Sync_lock.use driver.root.core.lock @@ fun () ->
                    Option.get (Atomic.get driver.root.core.failure)
                  in
                  set_state driver
                    (Crash_detected_pending (failure, post_commit));
                  wake driver;
                  Ok ())
      in
      Crux_telemetry.delivery body
    in
    {
      projection;
      reason;
      lock = delivery_lock;
      completed = false;
      answer;
    }

  let create binding root =
    Eta.Sync_lock.use attachment_lock (fun () ->
        if Option.is_some binding.core.root then
          invalid_arg
            "Eta_crux.Driver.create: binding is already attached";
        (match Root.attach_driver root with
        | Ok () -> ()
        | Error `Root_already_started ->
            invalid_arg "Eta_crux.Driver.create: root is already started"
        | Error `Already_attached ->
            invalid_arg
              "Eta_crux.Driver.create: root already has a driver");
        binding.core.root <- Some root.core);
    Crux_attachment_barrier.run_after_lock ();
    let requests = Eta.Queue.unbounded () in
    let driver =
      {
        binding;
        root;
        requests;
        lock = Eta.Sync_lock.create ();
        state = Running;
        last_snapshot = None;
        next_request_token = 0L;
        request_commands = Seq_map.empty;
        remote_requests = String_map.empty;
        inbound_requests = String_map.empty;
      }
    in
    binding.core.push_request <-
      Some
        (fun event ->
          ignore (Eta.Queue.try_offer_now requests event : _));
    (match binding.mode with
    | Identity -> ()
    | Serialized serialized ->
        Serialized_session.set_wake serialized.candidate
          (fun () -> wake driver));
    binding.replace <-
      (fun candidate ->
        Crux_telemetry.session_replace
          (match binding.mode with
          | Identity -> Eta.Effect.fail Serialized_session.Closed
          | Serialized serialized ->
              Serialized_dispatch.replace_session driver serialized
                candidate));
    driver

  let rec poll_once driver =
    match Serialized_dispatch.serialized_incoming driver with
    | `Item frame ->
        Eta.Effect.finally
          (Serialized_dispatch.release_serialized_incoming driver)
          (Serialized_dispatch.handle_serialized_frame driver frame)
    | `Closed_with_error (_ : never) -> .
    | `Closed ->
        let open Eta.Syntax in
        let* () =
          Eta.Effect.finally
            (Serialized_dispatch.release_serialized_incoming driver)
            (Serialized_dispatch.handle_session_closed driver)
        in
        poll_driver driver
    | `Empty -> poll_driver driver

  and poll_driver driver =
    match Eta.Queue.poll_now driver.requests with
    | `Item request -> (
        match driver.binding.mode with
        | Identity -> Eta.Effect.pure (Some (Request request))
        | Serialized serialized ->
            Serialized_dispatch.dispatch_serialized_request driver serialized request)
    | `Closed_with_error (_ : never) -> .
    | `Closed | `Empty -> (
        match state driver with
        | Advancing | Delivering _ | Replacement_delivering _ ->
            Eta.Effect.pure None
        | Closed_done -> Eta.Effect.pure None
        | Stopped_closed_pending ->
            set_state driver Closed_done;
            Eta.Effect.pure (Some (Closed Stopped))
        | Crash_settled_pending settlement ->
            (match driver.binding.mode with
            | Identity ->
                set_state driver
                  (Crash_closed_pending settlement);
                Eta.Effect.pure
                  (Some
                     (Crash_detected
                        settlement.Failure.failure))
            | Serialized serialized ->
                (match
                   Serialized_session.send
                     serialized.candidate (fun seq ->
                       Wire.Frame.Crash_notify
                         {
                           seq;
                           failure =
                             Failure.portable
                               settlement.Failure.failure;
                         })
                 with
                | Ok sequence ->
                    set_state driver
                      (Crash_settled_notifying
                         (settlement, sequence))
                | Error _ ->
                    set_state driver
                      (Crash_closed_pending settlement));
                Eta.Effect.pure None)
        | Crash_settled_notifying _ ->
            Eta.Effect.pure None
        | Crash_closed_pending settlement ->
            set_state driver Closed_done;
            Eta.Effect.pure (Some (Closed (Crashed settlement)))
        | Crash_detected_pending (failure, post_commit) ->
            (match driver.binding.mode with
            | Identity ->
                set_state driver
                  (Crash_teardown (failure, post_commit));
                Eta.Effect.pure (Some (Crash_detected failure))
            | Serialized serialized ->
                (match
                   Serialized_session.send
                     serialized.candidate (fun seq ->
                       Wire.Frame.Crash_notify
                         {
                           seq;
                           failure =
                             Failure.portable failure;
                         })
                 with
                | Ok sequence ->
                    set_state driver
                      (Crash_notifying
                         (failure, post_commit, sequence))
                | Error _ ->
                    set_state driver
                      (Crash_teardown
                         (failure, post_commit)));
                Eta.Effect.pure None)
        | Crash_notifying _ -> Eta.Effect.pure None
        | Crash_teardown (failure, post_commit) ->
            let open Eta.Syntax in
            let+ terminal = start_post_commit driver post_commit in
            (match terminal with
            | Some (Crashed settlement) ->
                set_state driver Closed_done;
                Some (Closed (Crashed settlement))
            | Some Stopped ->
                set_state driver Closed_done;
                Some (Closed Stopped)
            | None ->
                set_state driver (Crash_teardown (failure, post_commit));
                None)
        | Running -> (
            let claimed =
              Eta.Sync_lock.use driver.lock @@ fun () ->
              match driver.state, driver.binding.mode with
              | Running, Serialized serialized
                when serialized.replacement_pending ->
                  false
              | Running, _ ->
                  driver.state <- Advancing;
                  true
              | Advancing, _
              | Delivering _, _
              | Replacement_delivering _, _
              | Crash_detected_pending _, _
              | Crash_notifying _, _
              | Crash_teardown _, _
              | Crash_settled_pending _, _
              | Crash_settled_notifying _, _
              | Crash_closed_pending _, _
              | Stopped_closed_pending, _
              | Closed_done, _ ->
                  false
            in
            if not claimed then Eta.Effect.pure None
            else
            let open Eta.Syntax in
            let* result, duration_ms =
              Crux_telemetry.timed_if_metrics (fun () ->
                  Root.advance_driver driver.root)
              |> Crux_telemetry.advance
            in
            let trigger_and_outcome =
              match result with
              | Ok (Root.Committed _) ->
                  Some
                    ( (if Option.is_none driver.last_snapshot then
                         "start"
                       else "action"),
                      "committed" )
              | Ok (Root.Rejected _) ->
                  Some ("action", "rejected")
              | Ok (Root.Failed failed) ->
                  let trigger =
                    if Option.is_none driver.last_snapshot then
                      "start"
                    else
                      match
                        failed.failure.Failure.primary.trigger
                      with
                      | Failure.Endpoint_action -> "action"
                      | _ -> "control"
                  in
                  Some (trigger, "failed")
              | Ok Root.Idle | Ok (Root.Stopped _) | Error _ ->
                  None
            in
            let* () =
              match trigger_and_outcome with
              | None -> Eta.Effect.unit
              | Some (trigger, outcome) ->
                  Crux_telemetry.advancement ~trigger ~outcome
                    ~duration_ms
            in
            match result with
            | Error Root.Already_advancing
            | Error Root.Awaiting_post_commit ->
                set_state driver Running;
                Eta.Effect.pure None
            | Error Root.Driver_attached ->
                invalid_arg
                  "Eta_crux.Driver: attached driver lost advancement authority"
            | Error Root.Closed ->
                set_state driver Closed_done;
                Eta.Effect.pure None
            | Ok Root.Idle ->
                set_state driver Running;
                Eta.Effect.pure None
            | Ok (Root.Rejected error) ->
                set_state driver Running;
                Eta.Effect.pure (Some (Rejected error))
            | Ok (Root.Committed committed) ->
                Crux_pull_barrier.run_before_publication ();
                let snapshot = Projection.Commit.snapshot committed.commit in
                let batch = Projection.Commit.batch committed.commit in
                let initial =
                  Eta.Sync_lock.use driver.lock @@ fun () ->
                  let initial = Option.is_none driver.last_snapshot in
                  driver.last_snapshot <- Some snapshot;
                  initial
                in
                Crux_pull_barrier.run_after_publication ();
                let projection = Projection.Updates batch in
                let delivery =
                  create_delivery driver ~initial
                    ~reason:Advancement projection
                    committed.post_commit
                in
                (match driver.binding.mode with
                | Identity ->
                    set_state driver (Delivering (delivery, None));
                    Eta.Effect.pure (Some (Deliver delivery))
                | Serialized serialized ->
                    let result =
                      Serialized_dispatch.send_advancement driver
                        serialized projection
                    in
                    (match result with
                    | Ok reply_to ->
                        set_state driver
                          (Delivering (delivery, Some reply_to));
                        Eta.Effect.pure None
                    | Error cause ->
                        Delivery.failed delivery cause
                        |> Eta.Effect.map_error absurd
                        |> Eta.Effect.map (fun _ -> None)))
            | Ok (Root.Stopped stopped) ->
                let open Eta.Syntax in
                let+ _ = start_post_commit driver stopped.post_commit in
                Some (Closed Stopped)
            | Ok (Root.Failed failed) ->
                (match driver.binding.mode with
                | Identity ->
                    set_state driver
                      (Crash_teardown
                         (failed.failure, failed.post_commit));
                    Eta.Effect.pure
                      (Some (Crash_detected failed.failure))
                | Serialized serialized ->
                    (match
                       Serialized_session.send
                         serialized.candidate (fun seq ->
                           Wire.Frame.Crash_notify
                             {
                               seq;
                               failure =
                                 Failure.portable
                                   failed.failure;
                             })
                     with
                    | Ok sequence ->
                        set_state driver
                          (Crash_notifying
                             ( failed.failure,
                               failed.post_commit,
                               sequence ))
                    | Error _ ->
                        set_state driver
                          (Crash_teardown
                             ( failed.failure,
                               failed.post_commit )));
                    Eta.Effect.pure None)))

  let poll driver =
    let open Eta.Syntax in
    let* event = poll_once driver in
    let* () =
      match event with
      | Some (Crash_detected failure) ->
          Crux_telemetry.root_crashed failure
      | Some (Closed Stopped) ->
          Crux_telemetry.root_stopped ()
      | Some (Closed (Crashed _)) ->
          Crux_telemetry.root_crash_settled ()
      | Some (Request _) ->
          Crux_telemetry.request Eta.Effect.unit
      | Some (Deliver _) | Some (Rejected _) | None ->
          Eta.Effect.unit
    in
    Eta.Effect.pure event

  let rec await driver =
    let open Eta.Syntax in
    let* event = poll driver in
    match event with
    | Some event -> Eta.Effect.pure event
    | None ->
        let wake =
          Eta.Queue.take driver.root.core.wake
          |> Eta.Effect.map_error (function
               | `Closed -> ()
               | `Closed_with_error (_ : never) -> .)
          |> Eta.Effect.ignore_errors
          |> Eta.Effect.map (fun () -> `Wake)
        in
        let* winner =
          match Root.earliest_deadline driver.root with
          | None -> wake
          | Some deadline ->
              Eta.Effect.race
                [
                  wake;
                  Root.sleep_until_deadline driver.root deadline
                  |> Eta.Effect.map (fun () -> `Deadline);
                ]
        in
        (match winner with
        | `Wake ->
            (* The wakeup was consumed; allow the next endpoint send to offer
               again. Clearing happens before the following poll, so a send
               that observed the flag as set already has its ingress message
               visible to that poll. *)
            Atomic.set driver.root.core.wake_signaled false
        | `Deadline -> ());
        await driver

  let request_stop driver =
    Root.request_stop driver.root;
    wake driver

  let latest_committed_snapshot (driver : t) =
    Eta.Sync_lock.use driver.lock @@ fun () -> driver.last_snapshot
end
