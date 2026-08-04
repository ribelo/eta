module Crux = Eta_crux

let absurd (value : Crux.never) = match value with _ -> .

module Incoming = struct
  type ('output, 'incoming) t = {
    send :
      'output ->
      'incoming ->
      (unit, Crux.Endpoint.admission_error) Eta.Effect.t;
  }

  let create ~send = { send }

  let none =
    {
      send =
        (fun _ (incoming : Crux.never) ->
          match incoming with _ -> .);
    }
end

module Test_shell = struct
  type ('output, 'error) t = {
    pp_error : Format.formatter -> 'error -> unit;
    deliver :
      'output Crux.Adapter.delivery ->
      (unit, 'error) Eta.Effect.t;
    request_event :
      Crux.Request.Driver_event.t ->
      (unit, 'error) Eta.Effect.t;
    crash_detected :
      Crux.Failure.t ->
      (unit, 'error) Eta.Effect.t;
  }
end

module Handle = struct
  type operation_error = Busy
  type inject_error = No_output | Ingress_closed

  type 'output frame_outcome =
    | Idle
    | Rejected of Crux.Root.delivery_error
    | Committed of 'output
    | Stopped
    | Crashed of Crux.Failure.settlement

  type 'output frame = {
    outcome : 'output frame_outcome;
    events : 'output Crux.Driver.event list;
  }

  type drain_status =
    | Idle
    | Limit_reached
    | Closed of Crux.Driver.terminal

  type 'output drain = {
    status : drain_status;
    events : 'output Crux.Driver.event list;
  }

  type 'output shell =
    | Shell : ('output, 'error) Test_shell.t -> 'output shell

  type ('output, 'incoming) t = {
    driver : 'output Crux.Driver.t;
    incoming : ('output, 'incoming) Incoming.t;
    shell : 'output shell;
    lock : Eta.Sync_lock.t;
    mutable busy : bool;
    mutable output : 'output option;
    mutable terminal : Crux.Driver.terminal option;
  }

  let create ~incoming ~shell root =
    let binding = Crux.Driver.Binding.identity [] in
    {
      driver = Crux.Driver.create binding root;
      incoming;
      shell = Shell shell;
      lock = Eta.Sync_lock.create ();
      busy = false;
      output = None;
      terminal = None;
    }

  let last_output handle =
    Eta.Sync_lock.use handle.lock @@ fun () -> handle.output

  let claim handle =
    Eta.Sync_lock.use handle.lock @@ fun () ->
    if handle.busy then false
    else (
      handle.busy <- true;
      true)

  let release handle =
    Eta.Sync_lock.use handle.lock @@ fun () -> handle.busy <- false

  let with_operation handle operation =
    if not (claim handle) then Eta.Effect.pure (Error Busy)
    else
      Eta.Effect.finally
        (Eta.Effect.sync (fun () -> release handle))
        (Eta.Effect.unit
        |> Eta.Effect.bind (fun () -> operation ())
        |> Eta.Effect.map (fun result -> Ok result))

  let note_terminal handle terminal =
    Eta.Sync_lock.use handle.lock @@ fun () ->
    handle.terminal <- Some terminal

  let inject handle incoming =
    match last_output handle with
    | None -> Eta.Effect.fail No_output
    | Some output ->
        handle.incoming.send output incoming
        |> Eta.Effect.map_error (function
             | Crux.Endpoint.Ingress_closed -> Ingress_closed)

  let answer_delivery handle shell delivery =
    let open Eta.Syntax in
    let delivered =
      {
        Crux.Adapter.output =
          Crux.Driver.Delivery.output delivery;
        reason = Crux.Driver.Delivery.reason delivery;
      }
    in
    let* exit = Eta.Effect.to_exit (shell.Test_shell.deliver delivered) in
    match exit with
    | Eta.Exit.Ok () ->
        let+ result =
          Crux.Driver.Delivery.delivered delivery
          |> Eta.Effect.map_error absurd
        in
        (match result with
        | Ok () ->
            Eta.Sync_lock.use handle.lock @@ fun () ->
            handle.output <- Some delivered.output
        | Error Crux.Driver.Delivery.Already_completed -> ());
        `Delivered
    | Eta.Exit.Error cause ->
        let packed =
          Crux.Failure.Packed_cause.make
            ~pp_error:shell.pp_error cause
        in
        let+ _ =
          Crux.Driver.Delivery.failed delivery packed
          |> Eta.Effect.map_error absurd
        in
        `Failed

  let answer_request shell event =
    let open Eta.Syntax in
    let* exit =
      Eta.Effect.to_exit (shell.Test_shell.request_event event)
    in
    match exit with
    | Eta.Exit.Ok () ->
        Crux.Request.Driver_event.accepted event
        |> Eta.Effect.map_error absurd
        |> Eta.Effect.map (fun _ -> ())
    | Eta.Exit.Error cause ->
        Crux.Request.Driver_event.failed event
          (Crux.Failure.Packed_cause.make
             ~pp_error:shell.pp_error cause)
        |> Eta.Effect.map_error absurd
        |> Eta.Effect.map (fun _ -> ())

  let notify_crash shell failure =
    Eta.Effect.to_exit (shell.Test_shell.crash_detected failure)
    |> Eta.Effect.map (fun _ -> ())

  let rec run_frame handle events =
    let open Eta.Syntax in
    let* event =
      Crux.Driver.poll handle.driver
      |> Eta.Effect.map_error absurd
    in
    match event with
    | None ->
        Eta.Effect.pure
          { outcome = Idle; events = List.rev events }
    | Some (Crux.Driver.Request request as event) ->
        let (Shell shell) = handle.shell in
        let* () = answer_request shell request in
        run_frame handle (event :: events)
    | Some (Crux.Driver.Deliver delivery as event) ->
        let (Shell shell) = handle.shell in
        let* answer = answer_delivery handle shell delivery in
        (match answer with
        | `Delivered ->
            Eta.Effect.pure
              {
                outcome =
                  Committed
                    (Crux.Driver.Delivery.output delivery);
                events = List.rev (event :: events);
              }
        | `Failed -> run_frame handle (event :: events))
    | Some (Crux.Driver.Rejected error as event) ->
        Eta.Effect.pure
          {
            outcome = Rejected error;
            events = List.rev (event :: events);
          }
    | Some (Crux.Driver.Crash_detected failure as event) ->
        let (Shell shell) = handle.shell in
        let* () = notify_crash shell failure in
        run_frame handle (event :: events)
    | Some (Crux.Driver.Closed terminal as event) ->
        note_terminal handle terminal;
        let outcome =
          match terminal with
          | Crux.Driver.Stopped -> Stopped
          | Crux.Driver.Crashed settlement ->
              Crashed settlement
        in
        Eta.Effect.pure
          { outcome; events = List.rev (event :: events) }

  let frame handle =
    with_operation handle (fun () -> run_frame handle [])

  let drain handle ~max_steps =
    if max_steps <= 0 then
      invalid_arg
        "Eta_crux_test.Handle.drain: max_steps must be positive";
    let rec loop steps events =
      if steps = max_steps then
        Eta.Effect.pure
          { status = Limit_reached; events = List.rev events }
      else
        let open Eta.Syntax in
        let* frame = run_frame handle [] in
        let events =
          List.rev_append frame.events events
        in
        match frame.outcome with
        | Idle ->
            Eta.Effect.pure
              { status = Idle; events = List.rev events }
        | Stopped ->
            Eta.Effect.pure
              {
                status = Closed Crux.Driver.Stopped;
                events = List.rev events;
              }
        | Crashed settlement ->
            Eta.Effect.pure
              {
                status =
                  Closed (Crux.Driver.Crashed settlement);
                events = List.rev events;
              }
        | Rejected _ | Committed _ ->
            loop (steps + 1) events
    in
    with_operation handle (fun () -> loop 0 [])

  let rec settle handle =
    let open Eta.Syntax in
    let* frame = run_frame handle [] in
    match frame.outcome with
    | Stopped -> Eta.Effect.pure Crux.Driver.Stopped
    | Crashed settlement ->
        Eta.Effect.pure (Crux.Driver.Crashed settlement)
    | Idle | Rejected _ | Committed _ -> settle handle

  let stop handle =
    with_operation handle (fun () ->
        Eta.Effect.sync (fun () ->
            Crux.Driver.request_stop handle.driver)
        |> Eta.Effect.bind (fun () -> settle handle))

  let poll handle =
    if not (claim handle) then Eta.Effect.pure (Error Busy)
    else
      Eta.Effect.finally
        (Eta.Effect.sync (fun () -> release handle))
        (Crux.Driver.poll handle.driver
        |> Eta.Effect.map_error absurd
        |> Eta.Effect.map (fun event ->
               Option.iter
                 (function
                   | Crux.Driver.Closed terminal ->
                       note_terminal handle terminal
                   | Deliver _ | Request _ | Rejected _
                   | Crash_detected _ ->
                       ())
                 event;
               Ok event))

  let await handle =
    if not (claim handle) then Eta.Effect.pure (Error Busy)
    else
      Eta.Effect.finally
        (Eta.Effect.sync (fun () -> release handle))
        (Crux.Driver.await handle.driver
        |> Eta.Effect.map_error absurd
        |> Eta.Effect.map (fun event ->
               (match event with
               | Crux.Driver.Closed terminal ->
                   note_terminal handle terminal
               | Deliver _ | Request _ | Rejected _
               | Crash_detected _ ->
                   ());
               Ok event))

  let delivery_delivered handle delivery =
    let open Eta.Syntax in
    let+ result =
      Crux.Driver.Delivery.delivered delivery
      |> Eta.Effect.map_error absurd
    in
    (match result with
    | Ok () ->
        Eta.Sync_lock.use handle.lock @@ fun () ->
        handle.output <-
          Some (Crux.Driver.Delivery.output delivery)
    | Error Crux.Driver.Delivery.Already_completed -> ());
    result

  let delivery_failed _handle delivery cause =
    Crux.Driver.Delivery.failed delivery cause
    |> Eta.Effect.map_error absurd

  let request_stop handle =
    Crux.Driver.request_stop handle.driver

  let cleanup handle =
    let open Eta.Syntax in
    let* terminal =
      Eta.Effect.sync (fun () ->
          Eta.Sync_lock.use handle.lock @@ fun () ->
          handle.terminal)
    in
    match terminal with
    | Some _ -> Eta.Effect.unit
    | None ->
        let* () =
          Eta.Effect.sync (fun () ->
              Crux.Driver.request_stop handle.driver)
        in
        let* terminal = settle handle in
        (match terminal with
        | Crux.Driver.Stopped -> Eta.Effect.unit
        | Crux.Driver.Crashed _ ->
            Eta.Effect.sync (fun () ->
                Alcotest.fail
                  "Eta_crux_test.Handle.use: unobserved root crash"))

  let use ~incoming ~shell root ~f =
    let handle = create ~incoming ~shell root in
    Eta.Effect.finally (cleanup handle) (f handle)
end
