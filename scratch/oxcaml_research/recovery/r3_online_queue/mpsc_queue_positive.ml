open! Portable

module Queue = Effet.Portable_queue

type producer_report : immutable_data = {
  pushed : int;
  full_retries : int;
}

type consumer_report : immutable_data = {
  taken : int;
  empty_retries : int;
  sum : int;
}

let rec produce queue producer_id total index full_retries =
  if index = total then { pushed = total; full_retries }
  else
    let value = (producer_id * 100_000) + index in
    match Queue.try_push queue value with
    | Queue.Pushed -> produce queue producer_id total (index + 1) full_retries
    | Queue.Full -> produce queue producer_id total index (full_retries + 1)
    | Queue.Closed -> failwith "queue closed while producer was active"

let rec consume queue remaining taken empty_retries sum =
  if remaining = 0 then { taken; empty_retries; sum }
  else
    match Queue.try_take queue with
    | Queue.Value value -> consume queue (remaining - 1) (taken + 1) empty_retries (sum + value)
    | Queue.Empty -> consume queue remaining taken (empty_retries + 1) sum
    | Queue.Closed_empty -> failwith "queue closed before consumer drained expected values"

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:4 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let backpressure_smoke () =
  let queue = Queue.create ~capacity:2 in
  match (Queue.try_push queue 1, Queue.try_push queue 2, Queue.try_push queue 3) with
  | Queue.Pushed, Queue.Pushed, Queue.Full -> (
      match Queue.try_take queue with
      | Queue.Value 1 -> (
          match Queue.try_push queue 3 with
          | Queue.Pushed ->
              Queue.close queue;
              if Queue.try_push queue 4 <> Queue.Closed then
                failwith "push after close was not rejected"
          | _ -> failwith "push after freeing capacity failed")
      | _ -> failwith "take did not return oldest value")
  | _ -> failwith "bounded backpressure did not trip at capacity"

let expected_sum per_producer =
  let each_range = (per_producer - 1) * per_producer / 2 in
  (per_producer * (100_000 + 200_000 + 300_000)) + (3 * each_range)

let () =
  backpressure_smoke ();
  let per_producer = 500 in
  let total = per_producer * 3 in
  let queue = Queue.create ~capacity:32 in
  let p1, p2, p3, consumer =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(p1, p2, p3, consumer) =
          Parallel.fork_join4 parallel
            (fun _ -> produce queue 1 per_producer 0 0)
            (fun _ -> produce queue 2 per_producer 0 0)
            (fun _ -> produce queue 3 per_producer 0 0)
            (fun _ -> consume queue total 0 0 0)
        in
        (p1, p2, p3, consumer)))
  in
  Queue.close queue;
  if consumer.taken <> total then failwith "consumer did not receive every value";
  if consumer.sum <> expected_sum per_producer then failwith "consumer sum mismatch";
  if p1.pushed + p2.pushed + p3.pushed <> total then failwith "producer count mismatch";
  Printf.printf
    "mpsc_queue_positive producers=3 consumer=1 capacity=32 total=%d sum=%d full_retries=%d empty_retries=%d close_rejects_push=true fifo_single_consumer=true\n%!"
    total consumer.sum
    (p1.full_retries + p2.full_retries + p3.full_retries)
    consumer.empty_retries
