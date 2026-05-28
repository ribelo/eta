# Daemon-shaped Work Without Daemons

Use `Effect.with_background` when a background loop should live exactly as long
as a foreground body. It is the structured version of "run this forever while I
use the handle".

The background child is cancelled when the body returns or fails. The child is
not awaited as part of the body result, so application code that must observe
background failure should report it through an owned queue, promise, or an
explicit `Supervisor.scoped` nursery.

## Stream Reader Scoped To A Handle

~~~ocaml
let with_reader flow use =
  Effect.with_background
    ~name:"stream.reader"
    (Effect.sync (fun () -> read_loop flow))
    (fun () -> use flow)
~~~

## Heartbeat Scoped To A Session

~~~ocaml
let with_heartbeat session use =
  let heartbeat =
    Effect.repeat (Schedule.spaced (Duration.seconds 5))
      (Effect.sync (fun () -> Session.ping session))
  in
  Effect.with_background ~name:"session.heartbeat" heartbeat (fun () -> use session)
~~~

## Accept Loop Scoped To A Server

~~~ocaml
let serve listener use =
  let accept_loop =
    Effect.sync (fun () ->
      let rec loop () =
        let flow = Listener.accept listener in
        handle_connection flow;
        loop ()
      in
      loop ())
  in
  Effect.with_background ~name:"server.accept" accept_loop use
~~~

## Acquire/release Plus Background Reader

~~~ocaml
let with_monitor ~sw ~net use =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(Effect.sync (fun () ->
         let state = Monitor.create () in
         let flow = Monitor.connect ~sw ~net in
         state, flow))
       ~release:(fun (_state, flow) ->
         Effect.sync (fun () -> Monitor.close flow))
    |> Effect.bind (fun (state, flow) ->
         Effect.with_background
           ~name:"monitor.reader"
           (Effect.sync (fun () -> Monitor.read_loop flow state))
           (fun () -> use state)))
~~~

Use `Effect.Private.daemon` only for runtime-owned infrastructure whose lifetime
is intentionally tied to the runtime rather than to a caller's lexical body.
