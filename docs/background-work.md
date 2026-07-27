# Daemon-shaped Work Without Daemons

Use `Effect.with_background` when a background loop should live exactly as long
as a foreground body. It is the structured version of "run this forever while I
use the handle".

The background child is cancelled and awaited when the body returns or fails.
If the child fails first, the body is cancelled and awaited and the child's cause
propagates. This fail-fast rule fits protocol readers and heartbeats whose death
invalidates the foreground work.

Use `Effect.with_supervised_background` when the child may fail without
interrupting the body. Its failure is recorded under supervision and is observed
only after the body ends. Best-effort work needs no third combinator: pass
`Effect.ignore_errors background` to the supervised variant.

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
    Effect.repeat
      ~schedule:(Schedule.spaced (Duration.seconds 5))
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
  let open Eta.Syntax in
  let acquire =
    Effect.sync (fun () ->
      let state = Monitor.create () in
      let flow = Monitor.connect ~sw ~net in
      state, flow)
  in
  let release (_state, flow) =
    Effect.sync (fun () -> Monitor.close flow)
  in
  let@ (state, flow) = Effect.with_resource ~acquire ~release in
  Effect.with_background
    ~name:"monitor.reader"
    (Effect.sync (fun () -> Monitor.read_loop flow state))
    (fun () -> use state)
~~~

Use `Effect.daemon` only for runtime-owned infrastructure whose lifetime
is intentionally tied to the runtime rather than to a caller's lexical body.

## Development note

The patterns above use `Eta.Effect` from the `eta` package and assume an
Eio-backed runtime from `eta_eio`. Set up the toolchain and run the test gate
as described in [README.md](../README.md#development).
