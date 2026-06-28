open Effet

let effect_result name f =
  Effect.thunk name f
  |> Effect.bind (function Ok value -> Effect.pure value | Error err -> Effect.fail err)

module Queue = struct
  type 'err error = Closed | Failed of 'err
  type 'err state = Open | Closed_state | Failed_state of 'err
  type ('a, 'err) item = Value of 'a | Stop

  type ('a, 'err) t = {
    capacity : int;
    stream : ('a, 'err) item Eio.Stream.t;
    state : 'err state Atomic.t;
  }

  let create ~capacity =
    { capacity; stream = Eio.Stream.create capacity; state = Atomic.make Open }

  let wake_waiters t =
    if Eio.Stream.length t.stream < t.capacity then Eio.Stream.add t.stream Stop

  let offer t value =
    effect_result "queue.offer" @@ fun () ->
    match Atomic.get t.state with
    | Open ->
        Eio.Stream.add t.stream (Value value);
        Ok ()
    | Closed_state -> Error Closed
    | Failed_state err -> Error (Failed err)

  let rec take_once t =
    match Eio.Stream.take t.stream with
    | Value value -> Ok value
    | Stop -> (
        wake_waiters t;
        match Atomic.get t.state with
        | Open -> take_once t
        | Closed_state -> Error Closed
        | Failed_state err -> Error (Failed err))

  let take t = effect_result "queue.take" (fun () -> take_once t)

  let close t =
    Effect.thunk "queue.close" @@ fun () ->
    Atomic.set t.state Closed_state;
    wake_waiters t

  let fail t err =
    Effect.thunk "queue.fail" @@ fun () ->
    Atomic.set t.state (Failed_state err);
    wake_waiters t
end

module Deferred = struct
  type resolve_error = Already_resolved

  type ('a, 'err) t = {
    promise : ('a, 'err) result Eio.Promise.t;
    resolver : ('a, 'err) result Eio.Promise.u;
  }

  let create () =
    let promise, resolver = Eio.Promise.create () in
    { promise; resolver }

  let await t = effect_result "deferred.await" (fun () -> Eio.Promise.await t.promise)

  let succeed t value =
    effect_result "deferred.succeed" @@ fun () ->
    if Eio.Promise.try_resolve t.resolver (Ok value) then Ok ()
    else Error Already_resolved

  let fail t err =
    effect_result "deferred.fail" @@ fun () ->
    if Eio.Promise.try_resolve t.resolver (Error err) then Ok ()
    else Error Already_resolved
end

module Pubsub = struct
  type error = Closed
  type 'a item = Value of 'a | Stop
  type 'a subscriber = { stream : 'a item Eio.Stream.t }

  type 'a t = {
    capacity : int;
    subscribers : 'a subscriber list ref;
    mutex : Eio.Mutex.t;
    closed : bool Atomic.t;
  }

  let create ~capacity =
    {
      capacity;
      subscribers = ref [];
      mutex = Eio.Mutex.create ();
      closed = Atomic.make false;
    }

  let subscribe t =
    effect_result "pubsub.subscribe" @@ fun () ->
    if Atomic.get t.closed then Error Closed
    else
      let subscriber = { stream = Eio.Stream.create t.capacity } in
      Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
          t.subscribers := subscriber :: !(t.subscribers));
      Ok subscriber

  let publish t value =
    effect_result "pubsub.publish" @@ fun () ->
    if Atomic.get t.closed then Error Closed
    else
      let dropped =
        Eio.Mutex.use_ro t.mutex @@ fun () ->
        !(t.subscribers)
        |> List.fold_left
             (fun dropped subscriber ->
               if Eio.Stream.length subscriber.stream >= t.capacity then dropped + 1
               else (
                 Eio.Stream.add subscriber.stream (Value value);
                 dropped))
             0
      in
      Ok dropped

  let take subscriber =
    effect_result "pubsub.take" @@ fun () ->
    match Eio.Stream.take subscriber.stream with
    | Value value -> Ok value
    | Stop ->
        Eio.Stream.add subscriber.stream Stop;
        Error Closed

  let close t =
    Effect.thunk "pubsub.close" @@ fun () ->
    Atomic.set t.closed true;
    Eio.Mutex.use_ro t.mutex (fun () ->
        List.iter
          (fun subscriber ->
            if Eio.Stream.length subscriber.stream < t.capacity then
              Eio.Stream.add subscriber.stream Stop)
          !(t.subscribers))
end

module Latch = struct
  type t = {
    mutable count : int;
    mutex : Eio.Mutex.t;
    condition : Eio.Condition.t;
  }

  let create count =
    if count < 0 then invalid_arg "Latch.create: count must be >= 0";
    { count; mutex = Eio.Mutex.create (); condition = Eio.Condition.create () }

  let count_down t =
    Effect.thunk "latch.count_down" @@ fun () ->
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
        if t.count > 0 then t.count <- t.count - 1;
        if t.count = 0 then Eio.Condition.broadcast t.condition)

  let await t =
    Effect.thunk "latch.await" @@ fun () ->
    Eio.Mutex.use_ro t.mutex (fun () ->
        while t.count > 0 do
          Eio.Condition.await t.condition t.mutex
        done)
end
