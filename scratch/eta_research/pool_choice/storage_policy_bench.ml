module PA = Portable.Atomic

type item = {
  id : int;
  last_return_tick : int PA.t;
  uses : int PA.t;
}

let atomic_incr cell = PA.fetch_and_add cell 1 |> ignore

let atomic_add cell value = PA.fetch_and_add cell value |> ignore

module type STORAGE = sig
  type t

  val name : string
  val create : capacity:int -> t
  val push : t -> item -> unit
  val pop : t -> item option
  val length : t -> int
  val cas_retries : t -> int
end

module Treiber_lifo : STORAGE = struct
  type node = { value : item; next : node option }

  type t = {
    head : node option PA.t;
    length : int PA.t;
    retries : int PA.t;
  }

  let name = "treiber_lifo_portable_atomic"

  let create ~capacity:_ =
    { head = PA.make None; length = PA.make 0; retries = PA.make 0 }

  let rec push t value =
    let next = PA.get t.head in
    let node = Some { value; next } in
    match PA.compare_and_set t.head ~if_phys_equal_to:next ~replace_with:node with
    | PA.Compare_failed_or_set_here.Set_here -> atomic_incr t.length
    | PA.Compare_failed_or_set_here.Compare_failed ->
        atomic_incr t.retries;
        push t value

  let rec pop t =
    match PA.get t.head with
    | None -> None
    | Some node as current -> (
        match
          PA.compare_and_set t.head ~if_phys_equal_to:current
            ~replace_with:node.next
        with
        | PA.Compare_failed_or_set_here.Set_here ->
            PA.fetch_and_add t.length (-1) |> ignore;
            Some node.value
        | PA.Compare_failed_or_set_here.Compare_failed ->
            atomic_incr t.retries;
            pop t)

  let length t = PA.get t.length

  let cas_retries t = PA.get t.retries
end

module Mutex_lifo : STORAGE = struct
  type t = {
    mutex : Mutex.t;
    mutable values : item list;
  }

  let name = "mutex_lifo"

  let create ~capacity:_ = { mutex = Mutex.create (); values = [] }

  let with_lock t f =
    Mutex.lock t.mutex;
    match f () with
    | value ->
        Mutex.unlock t.mutex;
        value
    | exception exn ->
        Mutex.unlock t.mutex;
        raise exn

  let push t value = with_lock t (fun () -> t.values <- value :: t.values)

  let pop t =
    with_lock t @@ fun () ->
    match t.values with
    | [] -> None
    | value :: rest ->
        t.values <- rest;
        Some value

  let length t = with_lock t (fun () -> List.length t.values)

  let cas_retries _ = 0
end

module Mutex_fifo : STORAGE = struct
  type t = {
    mutex : Mutex.t;
    values : item Queue.t;
  }

  let name = "mutex_fifo"

  let create ~capacity:_ = { mutex = Mutex.create (); values = Queue.create () }

  let with_lock t f =
    Mutex.lock t.mutex;
    match f () with
    | value ->
        Mutex.unlock t.mutex;
        value
    | exception exn ->
        Mutex.unlock t.mutex;
        raise exn

  let push t value = with_lock t (fun () -> Queue.push value t.values)

  let pop t =
    with_lock t @@ fun () ->
    if Queue.is_empty t.values then None else Some (Queue.pop t.values)

  let length t = with_lock t (fun () -> Queue.length t.values)

  let cas_retries _ = 0
end

module Stream_fifo : STORAGE = struct
  type t = {
    stream : item Eio.Stream.t;
    length : int PA.t;
  }

  let name = "eio_stream_fifo"

  let create ~capacity = { stream = Eio.Stream.create capacity; length = PA.make 0 }

  let push t value =
    Eio.Stream.add t.stream value;
    atomic_incr t.length

  let pop t =
    match Eio.Stream.take_nonblocking t.stream with
    | None -> None
    | Some value ->
        PA.fetch_and_add t.length (-1) |> ignore;
        Some value

  let length t = PA.get t.length

  let cas_retries _ = 0
end

type scenario = {
  name : string;
  pool_size : int;
  workers : int;
  iterations : int;
  warm_window_ticks : int;
  warm_penalty : int;
  cold_penalty : int;
  hold_yields : int;
  yield_every : int;
  sample_every : int;
}

type metrics = {
  tick : int PA.t;
  warm_hits : int PA.t;
  cold_hits : int PA.t;
  empty_pops : int PA.t;
  checksum : int PA.t;
  sample_next : int PA.t;
  samples_us : float array;
}

type result = {
  mode : string;
  candidate : string;
  scenario : string;
  wall_ms : int;
  ops : int;
  empty_pops : int;
  warm_hits : int;
  cold_hits : int;
  warm_pct : float;
  p50_us : float;
  p99_us : float;
  minor_words : float;
  promoted_words : float;
  major_words : float;
  active_items : int;
  min_uses : int;
  max_uses : int;
  final_length : int;
  cas_retries : int;
  checksum : int;
}

let candidates : (module STORAGE) list =
  [
    (module Treiber_lifo);
    (module Mutex_lifo);
    (module Mutex_fifo);
    (module Stream_fifo);
  ]

let scenarios =
  [
    {
      name = "neutral_overhead";
      pool_size = 64;
      workers = 16;
      iterations = 8_000;
      warm_window_ticks = 0;
      warm_penalty = 0;
      cold_penalty = 0;
      hold_yields = 1;
      yield_every = 1;
      sample_every = 64;
    };
    {
      name = "warm_reuse_matters";
      pool_size = 64;
      workers = 16;
      iterations = 8_000;
      warm_window_ticks = 32;
      warm_penalty = 2;
      cold_penalty = 80;
      hold_yields = 1;
      yield_every = 1;
      sample_every = 64;
    };
  ]

let make_items pool_size =
  Array.init pool_size (fun id ->
      {
        id;
        last_return_tick = PA.make (-1_000_000);
        uses = PA.make 0;
      })

let burn count seed =
  let rec loop n acc =
    if n <= 0 then acc
    else loop (n - 1) (((acc * 1103515245) + 12345) land 0x3fffffff)
  in
  loop count seed

let record_sample metrics started =
  let idx = PA.fetch_and_add metrics.sample_next 1 in
  if idx < Array.length metrics.samples_us then
    metrics.samples_us.(idx) <- (Unix.gettimeofday () -. started) *. 1_000_000.0

let percentile samples count p =
  if count = 0 then 0.0
  else (
    Array.sort compare samples;
    let rank =
      int_of_float (ceil ((float count *. p) -. 1.0)) |> max 0 |> min (count - 1)
    in
    samples.(rank))

let run_one (type s) ~mode ~run_workers (module S : STORAGE with type t = s)
    scenario =
  let storage = S.create ~capacity:(scenario.pool_size * 2) in
  let items = make_items scenario.pool_size in
  Array.iter (S.push storage) items;
  let sample_count =
    ((scenario.workers * scenario.iterations) / scenario.sample_every) + 1024
  in
  let metrics =
    {
      tick = PA.make 0;
      warm_hits = PA.make 0;
      cold_hits = PA.make 0;
      empty_pops = PA.make 0;
      checksum = PA.make 0;
      sample_next = PA.make 0;
      samples_us = Array.make sample_count 0.0;
    }
  in
  let worker worker_id yield =
    for i = 1 to scenario.iterations do
      let sampled = i mod scenario.sample_every = 0 in
      let started = if sampled then Unix.gettimeofday () else 0.0 in
      begin
        match S.pop storage with
        | None -> atomic_incr metrics.empty_pops
        | Some item ->
            let acquire_tick = PA.fetch_and_add metrics.tick 1 in
            let last_return_tick = PA.get item.last_return_tick in
            let age = acquire_tick - last_return_tick in
            let is_warm = age >= 0 && age <= scenario.warm_window_ticks in
            if is_warm then atomic_incr metrics.warm_hits
            else atomic_incr metrics.cold_hits;
            let penalty =
              if is_warm then scenario.warm_penalty else scenario.cold_penalty
            in
            PA.fetch_and_add item.uses 1 |> ignore;
            atomic_add metrics.checksum
              (burn penalty (item.id + worker_id + acquire_tick));
            for _ = 1 to scenario.hold_yields do
              yield ()
            done;
            let release_tick = PA.fetch_and_add metrics.tick 1 in
            PA.set item.last_return_tick release_tick;
            S.push storage item
      end;
      if sampled then record_sample metrics started;
      if scenario.yield_every > 0 && i mod scenario.yield_every = 0 then yield ()
    done
  in
  Gc.compact ();
  let before = Gc.stat () in
  let started = Unix.gettimeofday () in
  run_workers scenario.workers worker;
  let after = Gc.stat () in
  let wall_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let warm_hits = PA.get metrics.warm_hits in
  let cold_hits = PA.get metrics.cold_hits in
  let ops = warm_hits + cold_hits in
  let warm_pct =
    if ops = 0 then 0.0 else (float warm_hits *. 100.0) /. float ops
  in
  let sample_count =
    min (PA.get metrics.sample_next) (Array.length metrics.samples_us)
  in
  let samples = Array.sub metrics.samples_us 0 sample_count in
  let uses = Array.map (fun item -> PA.get item.uses) items in
  let active_items =
    Array.fold_left (fun acc n -> if n > 0 then acc + 1 else acc) 0 uses
  in
  let min_uses =
    Array.fold_left min max_int uses |> fun value ->
    if value = max_int then 0 else value
  in
  let max_uses = Array.fold_left max 0 uses in
  {
    mode;
    candidate = S.name;
    scenario = scenario.name;
    wall_ms;
    ops;
    empty_pops = PA.get metrics.empty_pops;
    warm_hits;
    cold_hits;
    warm_pct;
    p50_us = percentile (Array.copy samples) sample_count 0.50;
    p99_us = percentile samples sample_count 0.99;
    minor_words = after.Gc.minor_words -. before.Gc.minor_words;
    promoted_words = after.Gc.promoted_words -. before.Gc.promoted_words;
    major_words = after.Gc.major_words -. before.Gc.major_words;
    active_items;
    min_uses;
    max_uses;
    final_length = S.length storage;
    cas_retries = S.cas_retries storage;
    checksum = PA.get metrics.checksum;
  }

let run_eio_fibers (module S : STORAGE) scenario =
  run_one ~mode:"eio_fibers"
    ~run_workers:(fun workers worker ->
      Eio_main.run @@ fun _ ->
      Eio.Fiber.all
        (List.init workers (fun worker_id ->
             fun () -> worker worker_id Eio.Fiber.yield)))
    (module S) scenario

let run_domains (module S : STORAGE) scenario =
  run_one ~mode:"domains"
    ~run_workers:(fun workers worker ->
      List.init workers (fun worker_id ->
          Domain.spawn (fun () -> worker worker_id (fun () -> ())))
      |> List.iter Domain.join)
    (module S) scenario

let print_result result =
  Printf.printf
    "mode=%s scenario=%s candidate=%s wall_ms=%d ops=%d empty=%d warm_pct=%.2f p50_us=%.2f p99_us=%.2f minor_words=%.0f promoted_words=%.0f major_words=%.0f active_items=%d min_uses=%d max_uses=%d final_length=%d cas_retries=%d checksum=%d\n%!"
    result.mode result.scenario result.candidate result.wall_ms result.ops
    result.empty_pops result.warm_pct result.p50_us result.p99_us
    result.minor_words result.promoted_words result.major_words
    result.active_items result.min_uses result.max_uses result.final_length
    result.cas_retries result.checksum

let () =
  List.iter
    (fun scenario ->
      List.iter
        (fun candidate ->
          print_result (run_eio_fibers candidate scenario);
          print_result (run_domains candidate scenario))
        candidates)
    scenarios
