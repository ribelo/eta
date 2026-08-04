open Crux_graph

module Failure = Crux_failure.Failure
module Request = Crux_boundary.Request
module Driver = Crux_driver.Driver

module Adapter = struct
  type 'output delivery = {
    output : 'output;
    reason : Driver.Delivery.reason;
  }

  type ('output, 'error) resource =
    | Resource : {
        pp_error : Format.formatter -> 'error -> unit;
        acquire : ('binding, 'error) Eta.Effect.t;
        release : 'binding -> (unit, 'error) Eta.Effect.t;
        deliver :
          'binding -> 'output delivery -> (unit, 'error) Eta.Effect.t;
        request_event :
          'binding ->
          Request.Driver_event.t ->
          (unit, 'error) Eta.Effect.t;
        crash_detected :
          'binding -> Failure.t -> (unit, 'error) Eta.Effect.t;
      } -> ('output, 'error) resource

  let resource ~pp_error ~acquire ~release ~deliver ~request_event
      ~crash_detected =
    Resource
      {
        pp_error;
        acquire;
        release;
        deliver;
        request_event;
        crash_detected;
      }
end

module Hosted = struct
  module Control = struct
    type t = { request_stop : unit -> unit }
    let request_stop control = control.request_stop ()
  end

  let packed_cause pp_error cause =
    Failure.Packed_cause.make ~pp_error cause

  let rec settle driver =
    let open Eta.Syntax in
    Driver.request_stop driver;
    let* event = Driver.await driver |> Eta.Effect.map_error absurd in
    match event with
    | Driver.Deliver delivery ->
        let* _ =
          Driver.Delivery.delivered delivery
          |> Eta.Effect.map_error absurd
        in
        settle driver
    | Driver.Request _ | Driver.Rejected _
    | Driver.Crash_detected _ ->
        settle driver
    | Driver.Closed terminal -> Eta.Effect.pure terminal

  let run driver ~adapter =
    let stop_signal = Eta.Queue.unbounded () in
    let control =
      {
        Control.request_stop =
          (fun () ->
            Driver.request_stop driver;
            ignore (Eta.Queue.try_offer_now stop_signal () : _));
      }
    in
    let (Adapter.Resource resource) = adapter control in
    let rec loop binding pending_delivery () =
      let open Eta.Syntax in
      let* event = Driver.await driver |> Eta.Effect.map_error absurd in
      match event with
      | Driver.Deliver delivery ->
          pending_delivery := Some delivery;
          let delivered =
            {
              Adapter.output = Driver.Delivery.output delivery;
              reason = Driver.Delivery.reason delivery;
            }
          in
          let* exit =
            Eta.Effect.to_exit (resource.deliver binding delivered)
          in
          let* _ =
            match exit with
            | Eta.Exit.Ok () ->
                Driver.Delivery.delivered delivery
                |> Eta.Effect.map_error absurd
            | Eta.Exit.Error cause ->
                Driver.Delivery.failed delivery
                  (packed_cause resource.pp_error cause)
                |> Eta.Effect.map_error absurd
          in
          pending_delivery := None;
          loop binding pending_delivery ()
      | Driver.Request event ->
          let* exit =
            Eta.Effect.to_exit (resource.request_event binding event)
          in
          let* _ =
            match exit with
            | Eta.Exit.Ok () ->
                Request.Driver_event.accepted event
                |> Eta.Effect.map_error absurd
            | Eta.Exit.Error cause ->
                Request.Driver_event.failed event
                  (packed_cause resource.pp_error cause)
                |> Eta.Effect.map_error absurd
          in
          loop binding pending_delivery ()
      | Driver.Rejected _ -> loop binding pending_delivery ()
      | Driver.Crash_detected failure ->
          let* exit =
            Eta.Effect.to_exit
              (resource.crash_detected binding failure)
          in
          let* () =
            match exit with
            | Eta.Exit.Ok () -> Eta.Effect.unit
            | Eta.Exit.Error cause ->
                Eta.Effect.sync (fun () ->
                    latch_failure_record driver.root.core
                      (failure_record driver.root.core
                         ~origin:Failure.Crash_handler
                         ~trigger:Failure.Application_crash_handler
                         (packed_cause resource.pp_error cause)))
          in
          loop binding pending_delivery ()
      | Driver.Closed terminal -> Eta.Effect.pure terminal
    in
    let settle_ignoring_terminal () =
      settle driver |> Eta.Effect.map (fun _ -> ())
    in
    let acquire =
      Eta.Effect.race
        [
          Eta.Effect.map
            (fun exit -> `Acquisition exit)
            (Eta.Effect.to_exit resource.acquire);
          (Eta.Queue.take stop_signal
          |> Eta.Effect.or_die (function
               | `Closed -> Failure "hosted stop signal closed"
               | `Closed_with_error (_ : never) -> .)
          |> Eta.Effect.map (fun () -> `Stopped));
        ]
    in
    let open Eta.Syntax in
    let* acquisition = acquire in
    match acquisition with
    | `Stopped -> settle driver
    | `Acquisition (Eta.Exit.Error cause) ->
        let* () = settle_ignoring_terminal () in
        Eta.Spi.Expert.make (fun _ -> Eta.Exit.Error cause)
    | `Acquisition (Eta.Exit.Ok binding) ->
        Eta.Effect.with_resource
          ~acquire:(Eta.Effect.pure binding)
          ~release:resource.release
        @@ fun binding ->
        let pending_delivery = ref None in
        loop binding pending_delivery ()
        |> Eta.Effect.on_interrupt (fun _ ->
               let open Eta.Syntax in
               let* () =
                 match !pending_delivery with
                 | None -> Eta.Effect.unit
                 | Some delivery ->
                     Driver.Delivery.delivered delivery
                     |> Eta.Effect.map_error absurd
                     |> Eta.Effect.map (fun _ -> ())
               in
               settle_ignoring_terminal ())
end
