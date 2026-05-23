open Eta

type protocol = H1 | H2

type state =
  | Connecting
  | TLS_handshaking
  | ALPN_resolved_h1
  | ALPN_resolved_h2
  | Cancelled

type t = {
  id : int;
  protocol : protocol;
  delay : Duration.t;
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
  on_cancel : unit -> unit;
  on_resolve : unit -> unit;
  mutable state : state;
  mutable cancel_recorded : bool;
}

let create ~id ~protocol ~delay ~on_cancel ~on_resolve () =
  {
    id;
    protocol;
    delay;
    mutex = Eio.Mutex.create ();
    condition = Eio.Condition.create ();
    on_cancel;
    on_resolve;
    state = Connecting;
    cancel_recorded = false;
  }

let id t = t.id

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let state t = with_lock t @@ fun () -> t.state
let is_live = function Connecting | TLS_handshaking -> true | _ -> false

let protocol_of_state = function
  | ALPN_resolved_h1 -> Some H1
  | ALPN_resolved_h2 -> Some H2
  | Connecting | TLS_handshaking | Cancelled -> None

let resolved_state = function H1 -> ALPN_resolved_h1 | H2 -> ALPN_resolved_h2

let cancel t =
  let should_record =
    with_lock t @@ fun () ->
    if t.cancel_recorded then false
    else (
      t.cancel_recorded <- true;
      t.state <- Cancelled;
      Eio.Condition.broadcast t.condition;
      true)
  in
  if should_record then t.on_cancel ()

let start_or_wait t =
  with_lock t @@ fun () ->
  match protocol_of_state t.state with
  | Some protocol -> `Ready protocol
  | None -> (
      match t.state with
      | Connecting ->
          t.state <- TLS_handshaking;
          `Leader
      | TLS_handshaking -> `Wait
      | Cancelled -> `Cancelled
      | ALPN_resolved_h1 | ALPN_resolved_h2 -> assert false)

let await_resolved t =
  with_lock t @@ fun () ->
  while is_live t.state do
    Eio.Condition.await t.condition t.mutex
  done;
  match protocol_of_state t.state with
  | Some protocol -> `Resolved protocol
  | None -> `Cancelled

let finish t =
  let protocol = t.protocol in
  let should_record =
    with_lock t @@ fun () ->
    match t.state with
    | Cancelled -> false
    | _ ->
        t.state <- resolved_state protocol;
        Eio.Condition.broadcast t.condition;
        true
  in
  if should_record then t.on_resolve ();
  protocol

let resolve t =
  Effect.sync (fun () -> start_or_wait t)
  |> Effect.bind (function
       | `Ready protocol -> Effect.pure protocol
       | `Cancelled -> Effect.fail `Connection_cancelled
       | `Wait ->
           Effect.sync (fun () -> await_resolved t)
           |> Effect.bind (function
                | `Resolved protocol -> Effect.pure protocol
                | `Cancelled -> Effect.fail `Connection_cancelled)
       | `Leader ->
           Effect.delay t.delay (Effect.sync (fun () -> finish t)))
