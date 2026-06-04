type offer_result : immutable_data = Enqueued | Dropped | Closed

type 'a take = Item of 'a | Take_closed

type 'a t = {
  capacity : int;
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
  queue : 'a Queue.t;
  mutable closed : bool;
  mutable dropped : int;
}

let create ?(capacity = 1024) () =
  if capacity <= 0 then invalid_arg "Eta_stream.Mailbox.create: capacity must be > 0";
  {
    capacity;
    mutex = Eio.Mutex.create ();
    condition = Eio.Condition.create ();
    queue = Queue.create ();
    closed = false;
    dropped = 0;
  }

let offer mailbox value =
  let result =
    Eio.Mutex.use_rw ~protect:false mailbox.mutex (fun () ->
        if mailbox.closed then Closed
        else if Queue.length mailbox.queue >= mailbox.capacity then (
          mailbox.dropped <- mailbox.dropped + 1;
          Dropped)
        else (
          Queue.add value mailbox.queue;
          Enqueued))
  in
  (match result with
  | Enqueued -> Eio.Condition.broadcast mailbox.condition
  | Dropped | Closed -> ());
  result

let close mailbox =
  Eio.Mutex.use_rw ~protect:false mailbox.mutex (fun () ->
      mailbox.closed <- true);
  Eio.Condition.broadcast mailbox.condition

let dropped mailbox = Eio.Mutex.use_ro mailbox.mutex (fun () -> mailbox.dropped)

let length mailbox =
  Eio.Mutex.use_ro mailbox.mutex (fun () -> Queue.length mailbox.queue)

let take mailbox =
  Eio.Mutex.lock mailbox.mutex;
  Fun.protect
    ~finally:(fun () -> Eio.Mutex.unlock mailbox.mutex)
    (fun () ->
      while Queue.is_empty mailbox.queue && not mailbox.closed do
        Eio.Condition.await mailbox.condition mailbox.mutex
      done;
      match Queue.take_opt mailbox.queue with
      | Some value -> Item value
      | None -> Take_closed)

let take_batch mailbox max =
  if max <= 0 then invalid_arg "Eta_stream.Mailbox.take_batch: max must be > 0";
  Eio.Mutex.lock mailbox.mutex;
  Fun.protect
    ~finally:(fun () -> Eio.Mutex.unlock mailbox.mutex)
    (fun () ->
      while Queue.is_empty mailbox.queue && not mailbox.closed do
        Eio.Condition.await mailbox.condition mailbox.mutex
      done;
      match Queue.take_opt mailbox.queue with
      | None -> Take_closed
      | Some first ->
          let rec drain remaining acc =
            if remaining = 0 then List.rev acc
            else
              match Queue.take_opt mailbox.queue with
              | None -> List.rev acc
              | Some value -> drain (remaining - 1) (value :: acc)
          in
          Item (drain (max - 1) [ first ]))
