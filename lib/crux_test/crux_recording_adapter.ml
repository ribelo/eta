module Crux = Eta_crux

type event =
  | Acquire
  | Deliver of Crux.Adapter.delivery
  | Request_event of Crux.Request.Driver_event.t
  | Crash_detected of Crux.Failure.t
  | Release

type 'error t = {
  pp_error : Format.formatter -> 'error -> unit;
  acquire : (unit, unit, 'error) Eta_test.Controlled.t;
  release : (unit, unit, 'error) Eta_test.Controlled.t;
  deliver :
    (Crux.Adapter.delivery, unit, 'error)
    Eta_test.Controlled.t;
  request_event :
    (Crux.Request.Driver_event.t, unit, 'error)
    Eta_test.Controlled.t;
  crash_detected :
    (Crux.Failure.t, unit, 'error) Eta_test.Controlled.t;
  lock : Eta.Sync_lock.t;
  mutable events_rev : event list;
}

let create ~pp_error =
  {
    pp_error;
    acquire = Eta_test.Controlled.create ();
    release = Eta_test.Controlled.create ();
    deliver = Eta_test.Controlled.create ();
    request_event = Eta_test.Controlled.create ();
    crash_detected = Eta_test.Controlled.create ();
    lock = Eta.Sync_lock.create ();
    events_rev = [];
  }

let record recorder event =
  Eta.Sync_lock.use recorder.lock @@ fun () ->
  recorder.events_rev <- event :: recorder.events_rev

let resource recorder =
  Crux.Adapter.resource ~pp_error:recorder.pp_error
    ~acquire:
      (Eta.Effect.sync (fun () -> record recorder Acquire)
      |> Eta.Effect.bind (fun () ->
             Eta_test.Controlled.eff recorder.acquire ()))
    ~release:(fun () ->
      Eta.Effect.sync (fun () -> record recorder Release)
      |> Eta.Effect.bind (fun () ->
             Eta_test.Controlled.eff recorder.release ()))
    ~deliver:(fun () delivery ->
      Eta.Effect.sync (fun () ->
          record recorder (Deliver delivery))
      |> Eta.Effect.bind (fun () ->
             Eta_test.Controlled.eff recorder.deliver
               delivery))
    ~request_event:(fun () event ->
      Eta.Effect.sync (fun () ->
          record recorder (Request_event event))
      |> Eta.Effect.bind (fun () ->
             Eta_test.Controlled.eff
               recorder.request_event event))
    ~crash_detected:(fun () failure ->
      Eta.Effect.sync (fun () ->
          record recorder (Crash_detected failure))
      |> Eta.Effect.bind (fun () ->
             Eta_test.Controlled.eff
               recorder.crash_detected failure))

let acquire_control recorder = recorder.acquire
let release_control recorder = recorder.release
let delivery_control recorder = recorder.deliver
let request_control recorder = recorder.request_event
let crash_control recorder = recorder.crash_detected

let events recorder =
  Eta.Sync_lock.use recorder.lock @@ fun () ->
  List.rev recorder.events_rev
