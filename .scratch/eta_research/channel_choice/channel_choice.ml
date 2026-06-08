open Eta

type error = Closed_error
type send_result = Sent | Full | Closed

type stats = {
  sent : int;
  received : int;
  closed : bool;
  dropped : int;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
  max_depth : int;
  final_depth : int;
}

module type CHANNEL = sig
  type t

  val label : string
  val create : int -> t
  val send : t -> int -> (unit, error) Effect.t
  val try_send : t -> int -> send_result
  val recv : t -> (int, error) Effect.t
  val try_recv : t -> int option
  val close : t -> unit
  val stats : t -> stats
end

let update_max current value = if value > current then value else current

module Mutex_queue : CHANNEL = struct
  type t = {
    capacity : int;
    mutex : Eio.Mutex.t;
    condition : Eio.Condition.t;
    queue : int Queue.t;
    mutable closed : bool;
    mutable sent : int;
    mutable received : int;
    mutable dropped : int;
    mutable waiting_senders : int;
    mutable waiting_receivers : int;
    mutable cancelled_senders : int;
    mutable max_depth : int;
  }

  let label = "mutex_queue"

  let create capacity =
    if capacity <= 0 then invalid_arg "mutex_queue: capacity <= 0";
    {
      capacity;
      mutex = Eio.Mutex.create ();
      condition = Eio.Condition.create ();
      queue = Queue.create ();
      closed = false;
      sent = 0;
      received = 0;
      dropped = 0;
      waiting_senders = 0;
      waiting_receivers = 0;
      cancelled_senders = 0;
      max_depth = 0;
    }

  let depth t = Queue.length t.queue

  let send_sync t value =
    Eio.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
      (fun () ->
        while depth t >= t.capacity && not t.closed do
          t.waiting_senders <- t.waiting_senders + 1;
          (match Eio.Condition.await t.condition t.mutex with
          | () -> t.waiting_senders <- t.waiting_senders - 1
          | exception exn ->
              t.waiting_senders <- t.waiting_senders - 1;
              t.cancelled_senders <- t.cancelled_senders + 1;
              raise exn)
        done;
        if t.closed then Closed
        else (
          Queue.add value t.queue;
          t.sent <- t.sent + 1;
          t.max_depth <- update_max t.max_depth (depth t);
          Eio.Condition.broadcast t.condition;
          Sent))

  let send t value =
    Effect.named (label ^ ".send") (Effect.sync (fun () -> send_sync t value))
    |> Effect.bind (function
         | Sent -> Effect.unit
         | Closed -> Effect.fail Closed_error
         | Full -> assert false)

  let try_send t value =
    let result =
      Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
          if t.closed then Closed
          else if depth t >= t.capacity then (
            t.dropped <- t.dropped + 1;
            Full)
          else (
            Queue.add value t.queue;
            t.sent <- t.sent + 1;
            t.max_depth <- update_max t.max_depth (depth t);
            Sent))
    in
    (match result with Sent -> Eio.Condition.broadcast t.condition | _ -> ());
    result

  let recv_sync t =
    Eio.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
      (fun () ->
        while Queue.is_empty t.queue && not t.closed do
          t.waiting_receivers <- t.waiting_receivers + 1;
          (match Eio.Condition.await t.condition t.mutex with
          | () -> t.waiting_receivers <- t.waiting_receivers - 1
          | exception exn ->
              t.waiting_receivers <- t.waiting_receivers - 1;
              raise exn)
        done;
        match Queue.take_opt t.queue with
        | Some value ->
            t.received <- t.received + 1;
            Eio.Condition.broadcast t.condition;
            Some value
        | None -> None)

  let recv t =
    Effect.named (label ^ ".recv") (Effect.sync (fun () -> recv_sync t))
    |> Effect.bind (function Some value -> Effect.pure value | None -> Effect.fail Closed_error)

  let try_recv t =
    let result =
      Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
          match Queue.take_opt t.queue with
          | None -> None
          | Some value ->
              t.received <- t.received + 1;
              Some value)
    in
    (match result with Some _ -> Eio.Condition.broadcast t.condition | None -> ());
    result

  let close t =
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> t.closed <- true);
    Eio.Condition.broadcast t.condition

  let stats t =
    Eio.Mutex.use_ro t.mutex (fun () ->
        {
          sent = t.sent;
          received = t.received;
          closed = t.closed;
          dropped = t.dropped;
          waiting_senders = t.waiting_senders;
          waiting_receivers = t.waiting_receivers;
          cancelled_senders = t.cancelled_senders;
          max_depth = t.max_depth;
          final_depth = depth t;
        })
end

module Mutex_ring : CHANNEL = struct
  type t = {
    capacity : int;
    mutex : Eio.Mutex.t;
    condition : Eio.Condition.t;
    buffer : int array;
    mutable head : int;
    mutable length : int;
    mutable closed : bool;
    mutable sent : int;
    mutable received : int;
    mutable dropped : int;
    mutable waiting_senders : int;
    mutable waiting_receivers : int;
    mutable cancelled_senders : int;
    mutable max_depth : int;
  }

  let label = "mutex_ring_int"

  let create capacity =
    if capacity <= 0 then invalid_arg "mutex_ring: capacity <= 0";
    {
      capacity;
      mutex = Eio.Mutex.create ();
      condition = Eio.Condition.create ();
      buffer = Array.make capacity 0;
      head = 0;
      length = 0;
      closed = false;
      sent = 0;
      received = 0;
      dropped = 0;
      waiting_senders = 0;
      waiting_receivers = 0;
      cancelled_senders = 0;
      max_depth = 0;
    }

  let push t value =
    let idx = (t.head + t.length) mod t.capacity in
    t.buffer.(idx) <- value;
    t.length <- t.length + 1;
    t.sent <- t.sent + 1;
    t.max_depth <- update_max t.max_depth t.length

  let pop t =
    if t.length = 0 then None
    else
      let value = t.buffer.(t.head) in
      t.head <- (t.head + 1) mod t.capacity;
      t.length <- t.length - 1;
      t.received <- t.received + 1;
      Some value

  let send_sync t value =
    Eio.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
      (fun () ->
        while t.length >= t.capacity && not t.closed do
          t.waiting_senders <- t.waiting_senders + 1;
          (match Eio.Condition.await t.condition t.mutex with
          | () -> t.waiting_senders <- t.waiting_senders - 1
          | exception exn ->
              t.waiting_senders <- t.waiting_senders - 1;
              t.cancelled_senders <- t.cancelled_senders + 1;
              raise exn)
        done;
        if t.closed then Closed
        else (
          push t value;
          Eio.Condition.broadcast t.condition;
          Sent))

  let send t value =
    Effect.named (label ^ ".send") (Effect.sync (fun () -> send_sync t value))
    |> Effect.bind (function
         | Sent -> Effect.unit
         | Closed -> Effect.fail Closed_error
         | Full -> assert false)

  let try_send t value =
    let result =
      Eio.Mutex.use_rw ~protect:false t.mutex (fun () ->
          if t.closed then Closed
          else if t.length >= t.capacity then (
            t.dropped <- t.dropped + 1;
            Full)
          else (
            push t value;
            Sent))
    in
    (match result with Sent -> Eio.Condition.broadcast t.condition | _ -> ());
    result

  let recv_sync t =
    Eio.Mutex.lock t.mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
      (fun () ->
        while t.length = 0 && not t.closed do
          t.waiting_receivers <- t.waiting_receivers + 1;
          (match Eio.Condition.await t.condition t.mutex with
          | () -> t.waiting_receivers <- t.waiting_receivers - 1
          | exception exn ->
              t.waiting_receivers <- t.waiting_receivers - 1;
              raise exn)
        done;
        let result = pop t in
        (match result with Some _ -> Eio.Condition.broadcast t.condition | None -> ());
        result)

  let recv t =
    Effect.named (label ^ ".recv") (Effect.sync (fun () -> recv_sync t))
    |> Effect.bind (function Some value -> Effect.pure value | None -> Effect.fail Closed_error)

  let try_recv t =
    let result = Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> pop t) in
    (match result with Some _ -> Eio.Condition.broadcast t.condition | None -> ());
    result

  let close t =
    Eio.Mutex.use_rw ~protect:false t.mutex (fun () -> t.closed <- true);
    Eio.Condition.broadcast t.condition

  let stats t =
    Eio.Mutex.use_ro t.mutex (fun () ->
        {
          sent = t.sent;
          received = t.received;
          closed = t.closed;
          dropped = t.dropped;
          waiting_senders = t.waiting_senders;
          waiting_receivers = t.waiting_receivers;
          cancelled_senders = t.cancelled_senders;
          max_depth = t.max_depth;
          final_depth = t.length;
        })
end

let candidates : (module CHANNEL) list =
  [ (module Mutex_queue); (module Mutex_ring) ]

let run_effect eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected Eta failure: %a\n%!"
        (Cause.pp (fun ppf Closed_error -> Format.pp_print_string ppf "closed"))
        cause;
      exit 1

let rec repeat_effect n f =
  if n <= 0 then Effect.unit
  else f () |> Effect.bind (fun () -> repeat_effect (n - 1) f)

let rec recv_n ch n sum recv =
  if n <= 0 then Effect.pure sum
  else recv ch |> Effect.bind (fun value -> recv_n ch (n - 1) (sum + value) recv)

let stress (module C : CHANNEL) =
  let producers = 24 in
  let per_producer = 160 in
  let total = producers * per_producer in
  let ch = C.create 16 in
  let producer pid =
    repeat_effect per_producer (fun () -> C.send ch pid)
  in
  let all_producers =
    Effect.for_each_par (List.init producers Fun.id) producer
    |> Effect.map (fun _ -> ())
  in
  let consumer = recv_n ch total 0 C.recv in
  let started = Unix.gettimeofday () in
  let sum = run_effect (Effect.par all_producers consumer |> Effect.map snd) in
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let stats = C.stats ch in
  Printf.printf
    "stress candidate=%s elapsed_ms=%d sum=%d sent=%d received=%d max_depth=%d final_depth=%d waiting_senders=%d waiting_receivers=%d cancelled_senders=%d\n%!"
    C.label elapsed_ms sum stats.sent stats.received stats.max_depth
    stats.final_depth stats.waiting_senders stats.waiting_receivers
    stats.cancelled_senders

let cancel_blocked_sender (module C : CHANNEL) =
  let ch = C.create 1 in
  match C.try_send ch 1 with
  | Sent ->
      let effect =
        Effect.race
          [
            (C.send ch 2 |> Effect.map (fun () -> "sent"));
            Effect.delay (Duration.ms 2) (Effect.pure "cancelled");
          ]
        |> Effect.bind (fun outcome ->
               C.recv ch |> Effect.map (fun value -> (outcome, value)))
      in
      let outcome, value = run_effect effect in
      C.close ch;
      let stats = C.stats ch in
      Printf.printf
        "cancel_blocked_sender candidate=%s outcome=%s received=%d sent=%d stats_received=%d final_depth=%d waiting_senders=%d cancelled_senders=%d\n%!"
        C.label outcome value stats.sent stats.received stats.final_depth
        stats.waiting_senders stats.cancelled_senders
  | Full | Closed -> failwith "initial try_send failed"

let close_blocked_sender (module C : CHANNEL) =
  let ch = C.create 1 in
  match C.try_send ch 1 with
  | Sent ->
      let blocked =
        C.send ch 2
        |> Effect.map (fun () -> "sent")
        |> Effect.catch (fun Closed_error -> Effect.pure "closed")
      in
      let closer =
        Effect.delay (Duration.ms 2)
          (Effect.named "channel.close" (Effect.sync (fun () ->
               C.close ch;
               "close_called")))
      in
      let outcomes = run_effect (Effect.all [ blocked; closer ]) in
      let first = Option.value (C.try_recv ch) ~default:(-1) in
      let stats = C.stats ch in
      Printf.printf
        "close_blocked_sender candidate=%s outcomes=%s drained=%d sent=%d received=%d closed=%b final_depth=%d waiting_senders=%d cancelled_senders=%d\n%!"
        C.label (String.concat "," outcomes) first stats.sent stats.received
        stats.closed stats.final_depth stats.waiting_senders
        stats.cancelled_senders
  | Full | Closed -> failwith "initial try_send failed"

let allocation_probe (module C : CHANNEL) =
  let ch = C.create 1 in
  Gc.compact ();
  let before = Gc.stat () in
  for i = 1 to 20_000 do
    (match C.try_send ch i with Sent -> () | Full | Closed -> assert false);
    match C.try_recv ch with Some _ -> () | None -> assert false
  done;
  let after = Gc.stat () in
  Printf.printf
    "allocation_probe candidate=%s minor_words=%.0f promoted_words=%.0f major_words=%.0f\n%!"
    C.label
    (after.minor_words -. before.minor_words)
    (after.promoted_words -. before.promoted_words)
    (after.major_words -. before.major_words)

let mailbox_drop_smoke () =
  let mailbox = Stream.Mailbox.create ~capacity:1 () in
  let first = Stream.Mailbox.offer mailbox 1 in
  let second = Stream.Mailbox.offer mailbox 2 in
  Printf.printf "mailbox_drop_smoke first=%s second=%s dropped=%d\n%!"
    (match first with Enqueued -> "enqueued" | Dropped -> "dropped" | Closed -> "closed")
    (match second with Enqueued -> "enqueued" | Dropped -> "dropped" | Closed -> "closed")
    (Stream.Mailbox.dropped mailbox)

type stream_event = Item of int | Closed_marker

let eio_stream_close_gap_smoke () =
  Eio_main.run @@ fun _ ->
  let stream = Eio.Stream.create 1 in
  let closed = Atomic.make false in
  Eio.Stream.add stream (Item 1);
  let blocked_finished = Atomic.make false in
  Eio.Fiber.both
    (fun () ->
      Eio.Stream.add stream (Item 2);
      Atomic.set blocked_finished true)
    (fun () ->
      Eio.Fiber.yield ();
      Atomic.set closed true;
      let first =
        match Eio.Stream.take stream with Item value -> value | Closed_marker -> -1
      in
      Eio.Fiber.yield ();
      let second =
        match Eio.Stream.take_nonblocking stream with
        | Some (Item value) -> value
        | Some Closed_marker -> -1
        | None -> -2
      in
      Printf.printf
        "eio_stream_close_gap closed=%b first=%d second=%d blocked_finished=%b\n%!"
        (Atomic.get closed) first second (Atomic.get blocked_finished))

let () =
  List.iter stress candidates;
  List.iter cancel_blocked_sender candidates;
  List.iter close_blocked_sender candidates;
  List.iter allocation_probe candidates;
  mailbox_drop_smoke ();
  eio_stream_close_gap_smoke ()
