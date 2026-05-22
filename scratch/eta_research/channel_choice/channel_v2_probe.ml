open Eta

let run_ok rt eff =
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected error: %a@."
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
        cause;
      exit 1

let gc_words f =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let started = Unix.gettimeofday () in
  f ();
  let ended = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  ( ended -. started,
    after.minor_words -. before.minor_words,
    after.promoted_words -. before.promoted_words,
    after.major_words -. before.major_words )

module type CHANNEL = sig
  type 'a t

  type stats = {
    depth : int;
    sent : int;
    received : int;
    closed : bool;
    waiting_senders : int;
    waiting_receivers : int;
    cancelled_senders : int;
  }

  type send_result = [ `Sent | `Full | `Closed ]
  type 'a recv_result = [ `Item of 'a | `Empty | `Closed ]

  val create : capacity:int -> unit -> 'a t
  val send : 'a t -> 'a -> (unit, [> `Closed ]) Effect.t
  val recv : 'a t -> ('a, [> `Closed ]) Effect.t
  val try_send : 'a t -> 'a -> (send_result, 'err) Effect.t
  val try_recv : 'a t -> ('a recv_result, 'err) Effect.t
  val close : 'a t -> unit
  val stats : 'a t -> stats
end

module V1 : CHANNEL = struct
  type 'a t = {
    mutex : Eio.Mutex.t;
    condition : Eio.Condition.t;
    buffer : 'a option array;
    capacity : int;
    mutable head : int;
    mutable tail : int;
    mutable depth : int;
    mutable sent : int;
    mutable received : int;
    mutable closed : bool;
    mutable waiting_senders : int;
    mutable waiting_receivers : int;
    mutable cancelled_senders : int;
  }

  type stats = {
    depth : int;
    sent : int;
    received : int;
    closed : bool;
    waiting_senders : int;
    waiting_receivers : int;
    cancelled_senders : int;
  }

  type send_result = [ `Sent | `Full | `Closed ]
  type 'a recv_result = [ `Item of 'a | `Empty | `Closed ]

  let create ~capacity () =
    if capacity <= 0 then invalid_arg "Eta.Channel.create: capacity must be > 0";
    {
      mutex = Eio.Mutex.create ();
      condition = Eio.Condition.create ();
      buffer = Array.make capacity None;
      capacity;
      head = 0;
      tail = 0;
      depth = 0;
      sent = 0;
      received = 0;
      closed = false;
      waiting_senders = 0;
      waiting_receivers = 0;
      cancelled_senders = 0;
    }

  let broadcast t = Eio.Condition.broadcast t.condition

  let push t value =
    t.buffer.(t.tail) <- Some value;
    t.tail <- (t.tail + 1) mod t.capacity;
    t.depth <- t.depth + 1;
    t.sent <- t.sent + 1

  let pop t =
    match t.buffer.(t.head) with
    | None -> invalid_arg "Eta.Channel.pop: empty slot"
    | Some value ->
        t.buffer.(t.head) <- None;
        t.head <- (t.head + 1) mod t.capacity;
        t.depth <- t.depth - 1;
        t.received <- t.received + 1;
        value

  let send_sync t value =
    Eio.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
      (fun () ->
        if t.closed then `Closed
        else if t.depth < t.capacity then (
          push t value;
          broadcast t;
          `Sent)
        else
          let registered = ref false in
          let unregister () =
            if !registered then (
              t.waiting_senders <- t.waiting_senders - 1;
              registered := false)
          in
          let register () =
            if not !registered then (
              t.waiting_senders <- t.waiting_senders + 1;
              registered := true)
          in
          try
            while t.depth = t.capacity && not t.closed do
              register ();
              Eio.Condition.await t.condition t.mutex
            done;
            unregister ();
            if t.closed then `Closed
            else (
              push t value;
              broadcast t;
              `Sent)
          with
          | Eio.Cancel.Cancelled _ as exn ->
              unregister ();
              t.cancelled_senders <- t.cancelled_senders + 1;
              broadcast t;
              raise exn
          | exn ->
              unregister ();
              broadcast t;
              raise exn)

  let recv_sync t =
    Eio.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
      (fun () ->
        if t.depth > 0 then (
          let value = pop t in
          broadcast t;
          `Item value)
        else if t.closed then `Closed
        else
          let registered = ref false in
          let unregister () =
            if !registered then (
              t.waiting_receivers <- t.waiting_receivers - 1;
              registered := false)
          in
          let register () =
            if not !registered then (
              t.waiting_receivers <- t.waiting_receivers + 1;
              registered := true)
          in
          try
            while t.depth = 0 && not t.closed do
              register ();
              Eio.Condition.await t.condition t.mutex
            done;
            unregister ();
            if t.depth > 0 then (
              let value = pop t in
              broadcast t;
              `Item value)
            else `Closed
          with exn ->
            unregister ();
            broadcast t;
            raise exn)

  let send t value =
    Effect.sync (fun () -> send_sync t value)
    |> Effect.bind (function
         | `Sent -> Effect.unit
         | `Full -> assert false
         | `Closed -> Effect.fail `Closed)

  let recv t =
    Effect.sync (fun () -> recv_sync t)
    |> Effect.bind (function
         | `Item value -> Effect.pure value
         | `Empty -> assert false
         | `Closed -> Effect.fail `Closed)

  let try_send t value =
    Effect.sync @@ fun () ->
    Eio.Mutex.use_rw ~protect:false t.mutex @@ fun () ->
    if t.closed then `Closed
    else if t.depth = t.capacity then `Full
    else (
      push t value;
      broadcast t;
      `Sent)

  let try_recv t =
    Effect.sync @@ fun () ->
    Eio.Mutex.use_rw ~protect:false t.mutex @@ fun () ->
    if t.depth > 0 then (
      let value = pop t in
      broadcast t;
      `Item value)
    else if t.closed then `Closed
    else `Empty

  let close t =
    Eio.Mutex.use_rw ~protect:false t.mutex @@ fun () ->
    if not t.closed then (
      t.closed <- true;
      broadcast t)

  let stats t =
    Eio.Mutex.use_ro t.mutex @@ fun () ->
    {
      depth = t.depth;
      sent = t.sent;
      received = t.received;
      closed = t.closed;
      waiting_senders = t.waiting_senders;
      waiting_receivers = t.waiting_receivers;
      cancelled_senders = t.cancelled_senders;
    }
end

module V2 : CHANNEL = struct
  type send_result = [ `Sent | `Full | `Closed ]
  type 'a recv_result = [ `Item of 'a | `Empty | `Closed ]

  type 'a sender = {
    value : 'a;
    resolver : send_result Eio.Promise.u;
    mutable active : bool;
  }

  type 'a receiver = {
    resolver : 'a recv_result Eio.Promise.u;
    mutable active : bool;
  }

  type 'a t = {
    mutex : Eio.Mutex.t;
    buffer : 'a option array;
    senders : 'a sender Queue.t;
    receivers : 'a receiver Queue.t;
    capacity : int;
    mutable head : int;
    mutable tail : int;
    mutable depth : int;
    mutable sent : int;
    mutable received : int;
    mutable closed : bool;
    mutable waiting_senders : int;
    mutable waiting_receivers : int;
    mutable cancelled_senders : int;
  }

  type stats = {
    depth : int;
    sent : int;
    received : int;
    closed : bool;
    waiting_senders : int;
    waiting_receivers : int;
    cancelled_senders : int;
  }

  let create ~capacity () =
    if capacity <= 0 then invalid_arg "Eta.Channel.create: capacity must be > 0";
    {
      mutex = Eio.Mutex.create ();
      buffer = Array.make capacity None;
      senders = Queue.create ();
      receivers = Queue.create ();
      capacity;
      head = 0;
      tail = 0;
      depth = 0;
      sent = 0;
      received = 0;
      closed = false;
      waiting_senders = 0;
      waiting_receivers = 0;
      cancelled_senders = 0;
    }

  let push (t : 'a t) value =
    t.buffer.(t.tail) <- Some value;
    t.tail <- (t.tail + 1) mod t.capacity;
    t.depth <- t.depth + 1;
    t.sent <- t.sent + 1

  let pop (t : 'a t) =
    match t.buffer.(t.head) with
    | None -> invalid_arg "Eta.Channel.pop: empty slot"
    | Some value ->
        t.buffer.(t.head) <- None;
        t.head <- (t.head + 1) mod t.capacity;
        t.depth <- t.depth - 1;
        t.received <- t.received + 1;
        value

  let rec take_active_sender (q : 'a sender Queue.t) : 'a sender option =
    if Queue.is_empty q then None
    else
      let waiter = Queue.take q in
      if waiter.active then Some waiter else take_active_sender q

  let rec take_active_receiver (q : 'a receiver Queue.t) : 'a receiver option =
    if Queue.is_empty q then None
    else
      let waiter = Queue.take q in
      if waiter.active then Some waiter else take_active_receiver q

  let take_sender (t : 'a t) =
    match take_active_sender t.senders with
    | None -> None
    | Some sender ->
        sender.active <- false;
        t.waiting_senders <- t.waiting_senders - 1;
        Some sender

  let take_receiver (t : 'a t) =
    match take_active_receiver t.receivers with
    | None -> None
    | Some receiver ->
        receiver.active <- false;
        t.waiting_receivers <- t.waiting_receivers - 1;
        Some receiver

  let rec drain_buffer_to_receivers (t : 'a t) =
    if t.depth > 0 then
      match take_receiver t with
      | None -> ()
      | Some receiver ->
          let value = pop t in
          Eio.Promise.resolve receiver.resolver (`Item value);
          drain_buffer_to_receivers t

  let rec admit_waiting_senders (t : 'a t) =
    if (not t.closed) && t.depth < t.capacity then
      match take_sender t with
      | None -> ()
      | Some sender -> (
          if t.depth = 0 then
            match take_receiver t with
            | Some receiver ->
                t.sent <- t.sent + 1;
                t.received <- t.received + 1;
                Eio.Promise.resolve receiver.resolver (`Item sender.value);
                Eio.Promise.resolve sender.resolver `Sent;
                admit_waiting_senders t
            | None ->
                push t sender.value;
                Eio.Promise.resolve sender.resolver `Sent;
                admit_waiting_senders t
          else (
            push t sender.value;
            Eio.Promise.resolve sender.resolver `Sent;
            admit_waiting_senders t))

  let pump (t : 'a t) =
    drain_buffer_to_receivers t;
    admit_waiting_senders t

  let with_lock (t : 'a t) f =
    Eio.Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

  let enqueue_sender (t : 'a t) value =
    let promise, resolver = Eio.Promise.create () in
    let sender = { value; resolver; active = true } in
    Queue.push sender t.senders;
    t.waiting_senders <- t.waiting_senders + 1;
    (promise, sender)

  let enqueue_receiver (t : 'a t) =
    let promise, resolver = Eio.Promise.create () in
    let receiver = { resolver; active = true } in
    Queue.push receiver t.receivers;
    t.waiting_receivers <- t.waiting_receivers + 1;
    (promise, receiver)

  let cancel_sender (t : 'a t) (sender : 'a sender) =
    if sender.active then (
      sender.active <- false;
      t.waiting_senders <- t.waiting_senders - 1;
      t.cancelled_senders <- t.cancelled_senders + 1;
      pump t)

  let cancel_receiver (t : 'a t) (receiver : 'a receiver) =
    if receiver.active then (
      receiver.active <- false;
      t.waiting_receivers <- t.waiting_receivers - 1;
      pump t)

  let close_locked (t : 'a t) =
    if not t.closed then (
      t.closed <- true;
      let rec close_senders () =
        match take_sender t with
        | None -> ()
        | Some sender ->
            Eio.Promise.resolve sender.resolver `Closed;
            close_senders ()
      in
      let rec close_receivers () =
        match take_receiver t with
        | None -> ()
        | Some receiver ->
            Eio.Promise.resolve receiver.resolver `Closed;
            close_receivers ()
      in
      close_senders ();
      close_receivers ())

  let send_sync (t : 'a t) value =
    match
      with_lock t @@ fun () ->
      if t.closed then `Ready `Closed
      else
        match take_receiver t with
        | Some receiver when t.depth = 0 ->
            t.sent <- t.sent + 1;
            t.received <- t.received + 1;
            Eio.Promise.resolve receiver.resolver (`Item value);
            `Ready `Sent
        | Some receiver ->
            receiver.active <- true;
            t.waiting_receivers <- t.waiting_receivers + 1;
            Queue.push receiver t.receivers;
            if t.depth < t.capacity then (
              push t value;
              pump t;
              `Ready `Sent)
            else
              let promise, sender = enqueue_sender t value in
              `Wait (promise, sender)
        | None ->
            if t.depth < t.capacity then (
              push t value;
              `Ready `Sent)
            else
              let promise, sender = enqueue_sender t value in
              `Wait (promise, sender)
    with
    | `Ready result -> result
    | `Wait (promise, sender) -> (
        try Eio.Promise.await promise
        with Eio.Cancel.Cancelled _ as exn ->
          with_lock t (fun () -> cancel_sender t sender);
          raise exn)

  let recv_sync (t : 'a t) =
    match
      with_lock t @@ fun () ->
      if t.depth > 0 then (
        let value = pop t in
        pump t;
        `Ready (`Item value))
      else
        match take_sender t with
        | Some sender ->
            t.sent <- t.sent + 1;
            t.received <- t.received + 1;
            Eio.Promise.resolve sender.resolver `Sent;
            `Ready (`Item sender.value)
        | None ->
            if t.closed then `Ready `Closed
            else
              let promise, receiver = enqueue_receiver t in
              `Wait (promise, receiver)
    with
    | `Ready result -> result
    | `Wait (promise, receiver) -> (
        try Eio.Promise.await promise
        with Eio.Cancel.Cancelled _ as exn ->
          with_lock t (fun () -> cancel_receiver t receiver);
          raise exn)

  let send t value =
    Effect.sync (fun () -> send_sync t value)
    |> Effect.bind (function
         | `Sent -> Effect.unit
         | `Full -> assert false
         | `Closed -> Effect.fail `Closed)

  let recv t =
    Effect.sync (fun () -> recv_sync t)
    |> Effect.bind (function
         | `Item value -> Effect.pure value
         | `Empty -> assert false
         | `Closed -> Effect.fail `Closed)

  let try_send (t : 'a t) value =
    Effect.sync @@ fun () ->
    with_lock t @@ fun () ->
    if t.closed then `Closed
    else
      match take_receiver t with
      | Some receiver when t.depth = 0 ->
          t.sent <- t.sent + 1;
          t.received <- t.received + 1;
          Eio.Promise.resolve receiver.resolver (`Item value);
          `Sent
      | Some receiver ->
          receiver.active <- true;
          t.waiting_receivers <- t.waiting_receivers + 1;
          Queue.push receiver t.receivers;
          if t.depth = t.capacity then `Full
          else (
            push t value;
            pump t;
            `Sent)
      | None ->
          if t.depth = t.capacity then `Full
          else (
            push t value;
            `Sent)

  let try_recv (t : 'a t) =
    Effect.sync @@ fun () ->
    with_lock t @@ fun () ->
    if t.depth > 0 then (
      let value = pop t in
      pump t;
      `Item value)
    else
      match take_sender t with
      | Some sender ->
          t.sent <- t.sent + 1;
          t.received <- t.received + 1;
          Eio.Promise.resolve sender.resolver `Sent;
          `Item sender.value
      | None -> if t.closed then `Closed else `Empty

  let close (t : 'a t) = with_lock t @@ fun () -> close_locked t

  let stats (t : 'a t) =
    Eio.Mutex.use_ro t.mutex @@ fun () ->
    {
      depth = t.depth;
      sent = t.sent;
      received = t.received;
      closed = t.closed;
      waiting_senders = t.waiting_senders;
      waiting_receivers = t.waiting_receivers;
      cancelled_senders = t.cancelled_senders;
    }
end

let wait_until ?(attempts = 200) pred =
  let rec loop n =
    if pred () then ()
    else if n = 0 then failwith "condition did not become true"
    else (
      Eio_unix.sleep 0.001;
      loop (n - 1))
  in
  loop attempts

let probe_try label (module C : CHANNEL) rt =
  let ch = C.create ~capacity:1 () in
  let elapsed, minor, promoted, major =
    gc_words @@ fun () ->
    for i = 1 to 100_000 do
      (match run_ok rt (C.try_send ch i) with
      | `Sent -> ()
      | _ -> failwith "try_send");
      match run_ok rt (C.try_recv ch) with
      | `Item _ -> ()
      | _ -> failwith "try_recv"
    done
  in
  let stats = C.stats ch in
  Printf.printf
    "%s try_send_recv iterations=100000 elapsed_ms=%.3f minor_words=%.0f promoted_words=%.0f major_words=%.0f sent=%d received=%d depth=%d\n"
    label (elapsed *. 1000.0) minor promoted major stats.sent stats.received
    stats.depth

let probe_blocking ~name ~capacity ~producers ~per_producer label
    (module C : CHANNEL) rt sw =
  let ch = C.create ~capacity () in
  let total = producers * per_producer in
  let elapsed, minor, promoted, major =
    gc_words @@ fun () ->
    for p = 0 to producers - 1 do
      Eio.Fiber.fork ~sw (fun () ->
          for i = 1 to per_producer do
            run_ok rt (C.send ch ((p * per_producer) + i))
          done)
    done;
    for _ = 1 to total do
      ignore (run_ok rt (C.recv ch) : int)
    done
  in
  let stats = C.stats ch in
  Printf.printf
    "%s %s capacity=%d producers=%d total=%d elapsed_ms=%.3f minor_words=%.0f promoted_words=%.0f major_words=%.0f sent=%d received=%d depth=%d waiting_senders=%d waiting_receivers=%d cancelled_senders=%d\n"
    label name capacity producers total (elapsed *. 1000.0) minor promoted major
    stats.sent stats.received stats.depth stats.waiting_senders
    stats.waiting_receivers stats.cancelled_senders

let behavior_smoke label (module C : CHANNEL) rt sw =
  let ch = C.create ~capacity:1 () in
  run_ok rt (C.send ch 1);
  let cancel_ctx = ref None in
  let sender =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun ctx ->
        cancel_ctx := Some ctx;
        Runtime.run rt (C.send ch 2))
  in
  wait_until (fun () -> (C.stats ch).waiting_senders = 1);
  Option.iter (fun ctx -> Eio.Cancel.cancel ctx Exit) !cancel_ctx;
  (match Eio.Promise.await_exn sender with
  | Exit.Ok _ -> failwith (label ^ " expected cancellation")
  | Exit.Error _ -> ());
  let stats = C.stats ch in
  if stats.waiting_senders <> 0 || stats.depth <> 1 then
    failwith (label ^ " cancellation cleanup");
  C.close ch;
  match run_ok rt (C.try_recv ch) with
  | `Item 1 -> Printf.printf "%s behavior_smoke ok\n" label
  | _ -> failwith (label ^ " close drain")

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  behavior_smoke "v1" (module V1) rt sw;
  behavior_smoke "v2" (module V2) rt sw;
  probe_try "v1" (module V1) rt;
  probe_try "v2" (module V2) rt;
  probe_blocking ~name:"blocking_contention" ~capacity:16 ~producers:4
    ~per_producer:10_000 "v1" (module V1) rt sw;
  probe_blocking ~name:"blocking_contention" ~capacity:16 ~producers:4
    ~per_producer:10_000 "v2" (module V2) rt sw;
  probe_blocking ~name:"broadcast_stress" ~capacity:1 ~producers:16
    ~per_producer:5_000 "v1" (module V1) rt sw;
  probe_blocking ~name:"broadcast_stress" ~capacity:1 ~producers:16
    ~per_producer:5_000 "v2" (module V2) rt sw
