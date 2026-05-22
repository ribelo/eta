open Eta

module PA = Portable.Atomic

type error =
  | Pool_shutdown
  | Connect_failed of string
  | Release_failed of string

type config = {
  max_size : int;
  max_idle : int;
  idle_lifetime : Duration.t option;
  max_lifetime : Duration.t option;
  warm_window : Duration.t;
  warm_penalty : int;
  cold_penalty : int;
}

type connection = {
  id : int;
  created_ms : int;
  closed : int PA.t;
  unhealthy : int PA.t;
  uses : int PA.t;
}

type factory = {
  next_id : int PA.t;
  opened : int PA.t;
  closed : int PA.t;
  live : int PA.t;
  max_live : int PA.t;
}

type entry = {
  conn : connection;
  created_ms : int;
  last_used_ms : int PA.t;
}

type stats = {
  total : int;
  idle : int;
  in_use : int;
  waiting : int;
  max_size : int;
  acquired : int;
  opened_by_pool : int;
  closed_by_pool : int;
  health_rejected : int;
  cancelled_waiters : int;
  max_observed_in_use : int;
  warm_hits : int;
  cold_hits : int;
  wait_loops : int;
  events : int;
  checksum : int;
  shutting_down : bool;
  cas_retries : int;
}

module type STORAGE = sig
  type t

  val name : string
  val create : capacity:int -> t
  val push : t -> entry -> unit
  val pop : t -> entry option
  val length : t -> int
  val cas_retries : t -> int
end

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let duration_expired ~now duration started_at =
  now - started_at >= Duration.to_ms duration

let atomic_get_int cell = PA.fetch_and_add cell 0

let atomic_incr cell = PA.fetch_and_add cell 1 + 1

let atomic_decr cell = PA.fetch_and_add cell (-1) - 1

let atomic_add cell value = PA.fetch_and_add cell value |> ignore

let burn count seed =
  let rec loop n acc =
    if n <= 0 then acc
    else loop (n - 1) (((acc * 1103515245) + 12345) land 0x3fffffff)
  in
  loop count seed

let atomic_update_max cell value =
  let rec loop () =
    let old = atomic_get_int cell in
    if value <= old then ()
    else
      match PA.compare_and_set cell ~if_phys_equal_to:old ~replace_with:value with
      | PA.Compare_failed_or_set_here.Set_here -> ()
      | PA.Compare_failed_or_set_here.Compare_failed -> loop ()
  in
  loop ()

let try_incr_bounded cell max_value =
  let rec loop () =
    let old = atomic_get_int cell in
    if old >= max_value then false
    else
      match
        PA.compare_and_set cell ~if_phys_equal_to:old ~replace_with:(old + 1)
      with
      | PA.Compare_failed_or_set_here.Set_here -> true
      | PA.Compare_failed_or_set_here.Compare_failed -> loop ()
  in
  loop ()

let create_factory () =
  {
    next_id = PA.make 0;
    opened = PA.make 0;
    closed = PA.make 0;
    live = PA.make 0;
    max_live = PA.make 0;
  }

let open_connection (factory : factory) =
  Effect.named "pool_protocol.open_connection" (Effect.sync (fun () ->
      let id = atomic_incr factory.next_id in
      ignore (atomic_incr factory.opened : int);
      let live = atomic_incr factory.live in
      atomic_update_max factory.max_live live;
      {
        id;
        created_ms = now_ms ();
        closed = PA.make 0;
        unhealthy = PA.make (if id = 3 then 1 else 0);
        uses = PA.make 0;
      }))

let close_connection (factory : factory) (conn : connection) =
  Effect.named "pool_protocol.close_connection" (Effect.sync (fun () ->
      match
        PA.compare_and_set conn.closed ~if_phys_equal_to:0 ~replace_with:1
      with
      | PA.Compare_failed_or_set_here.Set_here ->
          ignore (atomic_incr factory.closed : int);
          ignore (atomic_decr factory.live : int)
      | PA.Compare_failed_or_set_here.Compare_failed -> ()))

let health_check (conn : connection) =
  atomic_get_int conn.closed = 0 && atomic_get_int conn.unhealthy = 0

let use_connection (conn : connection) =
  Effect.named "pool_protocol.use_connection" (Effect.sync (fun () ->
      if atomic_get_int conn.closed <> 0 then
        failwith (Printf.sprintf "connection %d used after close" conn.id);
      ignore (atomic_incr conn.uses : int)))

module Treiber_lifo : STORAGE = struct
  type node = { value : entry; next : node option }

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
    | PA.Compare_failed_or_set_here.Set_here ->
        ignore (atomic_incr t.length : int)
    | PA.Compare_failed_or_set_here.Compare_failed ->
        ignore (atomic_incr t.retries : int);
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
            ignore (atomic_decr t.length : int);
            Some node.value
        | PA.Compare_failed_or_set_here.Compare_failed ->
            ignore (atomic_incr t.retries : int);
            pop t)

  let length t = atomic_get_int t.length

  let cas_retries t = atomic_get_int t.retries
end

module Mutex_lifo : STORAGE = struct
  type t = {
    mutex : Mutex.t;
    mutable values : entry list;
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
    values : entry Queue.t;
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

module Make_pool (S : STORAGE) = struct
  type t = {
    config : config;
    factory : factory;
    idle : S.t;
    total : int PA.t;
    in_use : int PA.t;
    waiting : int PA.t;
    acquired : int PA.t;
    opened_by_pool : int PA.t;
    closed_by_pool : int PA.t;
    health_rejected : int PA.t;
    cancelled_waiters : int PA.t;
    max_observed_in_use : int PA.t;
    warm_hits : int PA.t;
    cold_hits : int PA.t;
    wait_loops : int PA.t;
    events : int PA.t;
    checksum : int PA.t;
    shutting_down : int PA.t;
  }

  let label = S.name

  let create ?(config =
    {
      max_size = 8;
      max_idle = 8;
      idle_lifetime = Some (Duration.seconds 30);
      max_lifetime = Some (Duration.seconds 60);
      warm_window = Duration.ms 5;
      warm_penalty = 0;
      cold_penalty = 0;
    }) factory =
    if config.max_size <= 0 then invalid_arg "pool_protocol: max_size <= 0";
    if config.max_idle < 0 then invalid_arg "pool_protocol: max_idle < 0";
    if config.max_idle > config.max_size then
      invalid_arg "pool_protocol: max_idle > max_size";
    Effect.named "pool_protocol.create" (Effect.sync (fun () ->
        {
          config;
          factory;
          idle = S.create ~capacity:(config.max_size * 2);
          total = PA.make 0;
          in_use = PA.make 0;
          waiting = PA.make 0;
          acquired = PA.make 0;
          opened_by_pool = PA.make 0;
          closed_by_pool = PA.make 0;
          health_rejected = PA.make 0;
          cancelled_waiters = PA.make 0;
          max_observed_in_use = PA.make 0;
          warm_hits = PA.make 0;
          cold_hits = PA.make 0;
          wait_loops = PA.make 0;
          events = PA.make 0;
          checksum = PA.make 0;
          shutting_down = PA.make 0;
        }))

  let stats t =
    {
      total = atomic_get_int t.total;
      idle = S.length t.idle;
      in_use = atomic_get_int t.in_use;
      waiting = atomic_get_int t.waiting;
      max_size = t.config.max_size;
      acquired = atomic_get_int t.acquired;
      opened_by_pool = atomic_get_int t.opened_by_pool;
      closed_by_pool = atomic_get_int t.closed_by_pool;
      health_rejected = atomic_get_int t.health_rejected;
      cancelled_waiters = atomic_get_int t.cancelled_waiters;
      max_observed_in_use = atomic_get_int t.max_observed_in_use;
      warm_hits = atomic_get_int t.warm_hits;
      cold_hits = atomic_get_int t.cold_hits;
      wait_loops = atomic_get_int t.wait_loops;
      events = atomic_get_int t.events;
      checksum = atomic_get_int t.checksum;
      shutting_down = atomic_get_int t.shutting_down <> 0;
      cas_retries = S.cas_retries t.idle;
    }

  let charge_reuse t entry is_warm =
    let penalty =
      if is_warm then t.config.warm_penalty else t.config.cold_penalty
    in
    if penalty > 0 then atomic_add t.checksum (burn penalty entry.conn.id)

  let record_acquired t entry =
    let in_use = atomic_incr t.in_use in
    atomic_update_max t.max_observed_in_use in_use;
    ignore (atomic_incr t.acquired : int);
    let now = now_ms () in
    let age = now - atomic_get_int entry.last_used_ms in
    let is_warm = age >= 0 && age <= Duration.to_ms t.config.warm_window in
    if is_warm then
      ignore (atomic_incr t.warm_hits : int)
    else ignore (atomic_incr t.cold_hits : int);
    charge_reuse t entry is_warm

  let should_close t now entry =
    atomic_get_int t.shutting_down <> 0
    ||
    match t.config.max_lifetime with
    | Some max_lifetime when duration_expired ~now max_lifetime entry.created_ms ->
        true
    | _ -> (
        match t.config.idle_lifetime with
        | Some idle_lifetime ->
            duration_expired ~now idle_lifetime (atomic_get_int entry.last_used_ms)
        | None -> false)

  let close_reserved t entry =
    ignore (atomic_decr t.in_use : int);
    ignore (atomic_decr t.total : int);
    ignore (atomic_incr t.closed_by_pool : int);
    ignore (atomic_incr t.events : int);
    close_connection t.factory entry.conn

  type reservation =
    | Shutdown
    | Wait
    | Open_new
    | Use of entry

  let reserve t =
    if atomic_get_int t.shutting_down <> 0 then Shutdown
    else
      match S.pop t.idle with
      | Some entry ->
          record_acquired t entry;
          Use entry
      | None ->
          if try_incr_bounded t.total t.config.max_size then (
            ignore (atomic_incr t.in_use : int);
            atomic_update_max t.max_observed_in_use (atomic_get_int t.in_use);
            ignore (atomic_incr t.opened_by_pool : int);
            ignore (atomic_incr t.events : int);
            Open_new)
          else Wait

  let wait_for_retry t =
    let completed = ref false in
    let register =
      Effect.named "pool_protocol.wait_register" (Effect.sync (fun () ->
          ignore (atomic_incr t.waiting : int);
          ignore (atomic_incr t.wait_loops : int);
          ignore (atomic_incr t.events : int)))
    in
    let release () =
      Effect.named "pool_protocol.wait_release" (Effect.sync (fun () ->
          ignore (atomic_decr t.waiting : int);
          if not !completed then ignore (atomic_incr t.cancelled_waiters : int)))
    in
    Effect.scoped
      (Effect.acquire_release ~acquire:register ~release
      |> Effect.bind (fun () ->
             Effect.delay (Duration.ms 1) Effect.unit
             |> Effect.map (fun () -> completed := true)))

  let rec acquire_entry t =
    Effect.named "pool_protocol.reserve" (Effect.sync (fun () -> reserve t))
    |> Effect.bind (function
         | Shutdown -> Effect.fail Pool_shutdown
         | Wait -> wait_for_retry t |> Effect.bind (fun () -> acquire_entry t)
         | Use entry ->
             let now = now_ms () in
             if should_close t now entry then
               close_reserved t entry |> Effect.bind (fun () -> acquire_entry t)
             else if health_check entry.conn then Effect.pure entry
             else (
               ignore (atomic_incr t.health_rejected : int);
               close_reserved t entry |> Effect.bind (fun () -> acquire_entry t))
         | Open_new ->
             open_connection t.factory
             |> Effect.bind (fun conn ->
                    let entry =
                      {
                        conn;
                        created_ms = conn.created_ms;
                        last_used_ms = PA.make (now_ms ());
                      }
                    in
                    if health_check conn then (
                      ignore (atomic_incr t.acquired : int);
                      ignore (atomic_incr t.cold_hits : int);
                      charge_reuse t entry false;
                      Effect.pure entry)
                    else (
                      ignore (atomic_incr t.health_rejected : int);
                      close_reserved t entry
                      |> Effect.bind (fun () -> acquire_entry t))))

  let release_entry t entry =
    Effect.named "pool_protocol.release" (Effect.sync (fun () ->
        let now = now_ms () in
        ignore (atomic_decr t.in_use : int);
        if
          atomic_get_int t.shutting_down <> 0
          || (match t.config.max_lifetime with
             | Some max_lifetime ->
                 duration_expired ~now max_lifetime entry.created_ms
             | None -> false)
          || S.length t.idle >= t.config.max_idle
        then (
          ignore (atomic_decr t.total : int);
          ignore (atomic_incr t.closed_by_pool : int);
          ignore (atomic_incr t.events : int);
          Some entry.conn)
        else (
          PA.set entry.last_used_ms now;
          S.push t.idle entry;
          ignore (atomic_incr t.events : int);
          None)))
    |> Effect.bind (function
         | None -> Effect.unit
         | Some conn -> close_connection t.factory conn)

  let with_resource t body =
    Effect.scoped
      (Effect.acquire_release ~acquire:(acquire_entry t) ~release:(release_entry t)
      |> Effect.bind (fun entry -> body entry.conn))

  let evict_idle t =
    let rec drain acc =
      match S.pop t.idle with
      | None -> acc
      | Some entry -> drain (entry :: acc)
    in
    Effect.named "pool_protocol.evict_partition" (Effect.sync (fun () ->
        let now = now_ms () in
        List.partition (should_close t now) (drain [])))
    |> Effect.bind (fun (expired, keep) ->
           List.iter (S.push t.idle) keep;
           List.map
             (fun entry ->
               ignore (atomic_decr t.total : int);
               ignore (atomic_incr t.closed_by_pool : int);
               close_connection t.factory entry.conn)
             expired
           |> Effect.concat)

  let shutdown ?(deadline = Duration.ms 250) t =
    PA.set t.shutting_down 1;
    let started = now_ms () in
    let rec wait_in_use () =
      if atomic_get_int t.in_use = 0 then Effect.unit
      else if now_ms () - started >= Duration.to_ms deadline then Effect.unit
      else Effect.delay (Duration.ms 1) (wait_in_use ())
    in
    evict_idle t |> Effect.bind wait_in_use |> Effect.bind (fun () -> evict_idle t)
end

module type CANDIDATE = sig
  type t

  val label : string
  val create : ?config:config -> factory -> (t, error) Effect.t
  val with_resource : t -> (connection -> ('a, error) Effect.t) -> ('a, error) Effect.t
  val evict_idle : t -> (unit, error) Effect.t
  val shutdown : ?deadline:Duration.t -> t -> (unit, error) Effect.t
  val stats : t -> stats
end

module Candidate (S : STORAGE) : CANDIDATE = struct
  module P = Make_pool (S)

  type t = P.t

  let label = P.label
  let create = P.create
  let with_resource = P.with_resource
  let evict_idle = P.evict_idle
  let shutdown = P.shutdown
  let stats = P.stats
end

let candidates : (module CANDIDATE) list =
  [
    (module Candidate (Treiber_lifo));
    (module Candidate (Mutex_lifo));
    (module Candidate (Mutex_fifo));
  ]

let run_effect eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Runtime.run rt eff with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected Eta failure: %a\n%!"
        (Cause.pp (fun fmt -> function
          | Pool_shutdown -> Format.pp_print_string fmt "Pool_shutdown"
          | Connect_failed msg -> Format.fprintf fmt "Connect_failed(%s)" msg
          | Release_failed msg -> Format.fprintf fmt "Release_failed(%s)" msg))
        cause;
      exit 1

let rec repeat_effect n f =
  if n <= 0 then Effect.unit
  else f () |> Effect.bind (fun () -> repeat_effect (n - 1) f)

let factory_summary factory =
  Printf.sprintf "opened=%d closed=%d live=%d max_live=%d"
    (atomic_get_int factory.opened) (atomic_get_int factory.closed)
    (atomic_get_int factory.live) (atomic_get_int factory.max_live)

let stats_summary stats =
  Printf.sprintf
    "total=%d idle=%d in_use=%d waiting=%d acquired=%d opened=%d closed=%d health_rejected=%d cancelled_waiters=%d max_in_use=%d warm=%d cold=%d wait_loops=%d events=%d checksum=%d cas_retries=%d shutdown=%b"
    stats.total stats.idle stats.in_use stats.waiting stats.acquired
    stats.opened_by_pool stats.closed_by_pool stats.health_rejected
    stats.cancelled_waiters stats.max_observed_in_use stats.warm_hits
    stats.cold_hits stats.wait_loops stats.events stats.checksum
    stats.cas_retries stats.shutting_down

let protocol_churn (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 8;
      max_idle = 8;
      idle_lifetime = Some (Duration.seconds 30);
      max_lifetime = Some (Duration.seconds 60);
      warm_window = Duration.ms 5;
      warm_penalty = 0;
      cold_penalty = 0;
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         let worker worker_id =
           repeat_effect 200 (fun () ->
               P.with_resource pool (fun conn ->
                   use_connection conn
                   |> Effect.bind (fun () ->
                          let hold_ms = if (conn.id + worker_id) mod 3 = 0 then 2 else 1 in
                          Effect.delay (Duration.ms hold_ms) Effect.unit)))
         in
         Effect.for_each_par (List.init 16 Fun.id) worker
         |> Effect.bind (fun _ -> P.shutdown pool)
         |> Effect.map (fun () -> (P.stats pool, factory)))

let protocol_warm_cache (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 64;
      max_idle = 64;
      idle_lifetime = Some (Duration.seconds 30);
      max_lifetime = Some (Duration.seconds 60);
      warm_window = Duration.ms 5;
      warm_penalty = 2;
      cold_penalty = 250;
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         let prefill =
           Effect.for_each_par (List.init 64 Fun.id) (fun _ ->
               P.with_resource pool (fun conn ->
                   use_connection conn
                   |> Effect.bind (fun () ->
                          Effect.delay (Duration.ms 5) Effect.unit)))
         in
         let active worker_id =
           repeat_effect 400 (fun () ->
               P.with_resource pool (fun conn ->
                   use_connection conn
                   |> Effect.bind (fun () ->
                          let hold_ms = if (conn.id + worker_id) mod 4 = 0 then 2 else 1 in
                          Effect.delay (Duration.ms hold_ms) Effect.unit)))
         in
         prefill
         |> Effect.bind (fun _ ->
                Effect.for_each_par (List.init 8 Fun.id) active)
         |> Effect.bind (fun _ -> P.shutdown pool)
         |> Effect.map (fun () -> (P.stats pool, factory)))

let cancellation_smoke (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 1;
      max_idle = 1;
      idle_lifetime = Some (Duration.seconds 30);
      max_lifetime = Some (Duration.seconds 60);
      warm_window = Duration.ms 5;
      warm_penalty = 0;
      cold_penalty = 0;
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         P.with_resource pool (fun holder ->
             use_connection holder
             |> Effect.bind (fun () ->
                    let holder_done =
                      Effect.delay (Duration.ms 20) (Effect.pure "holder_done")
                    in
                    let waiter =
                      Effect.delay (Duration.ms 1)
                        (P.with_resource pool (fun conn ->
                             use_connection conn
                             |> Effect.map (fun () -> "waiter_acquired")))
                    in
                    let cancel_first =
                      Effect.delay (Duration.ms 3) (Effect.pure "cancelled")
                    in
                    Effect.all_settled [ holder_done; Effect.race [ waiter; cancel_first ] ]))
         |> Effect.bind (fun outcomes ->
                P.shutdown pool
                |> Effect.map (fun () -> (outcomes, P.stats pool, factory))))

let idle_eviction_smoke (module P : CANDIDATE) =
  let factory = create_factory () in
  let config =
    {
      max_size = 2;
      max_idle = 2;
      idle_lifetime = Some (Duration.ms 2);
      max_lifetime = Some (Duration.seconds 60);
      warm_window = Duration.ms 5;
      warm_penalty = 0;
      cold_penalty = 0;
    }
  in
  P.create ~config factory
  |> Effect.bind (fun pool ->
         P.with_resource pool use_connection
         |> Effect.bind (fun () ->
                Effect.delay (Duration.ms 5)
                  (P.evict_idle pool
                  |> Effect.bind (fun () -> P.shutdown pool)
                  |> Effect.map (fun () -> (P.stats pool, factory)))))

let measure_effect label effect_of_candidate candidate =
  Gc.compact ();
  let before = Gc.stat () in
  let started = Unix.gettimeofday () in
  let stats, factory = run_effect (effect_of_candidate candidate) in
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  let after = Gc.stat () in
  let module P = (val candidate : CANDIDATE) in
  Printf.printf
    "%s candidate=%s wall_ms=%d minor_words=%.0f promoted_words=%.0f major_words=%.0f %s %s\n%!"
    label P.label elapsed_ms
    (after.minor_words -. before.minor_words)
    (after.promoted_words -. before.promoted_words)
    (after.major_words -. before.major_words)
    (stats_summary stats) (factory_summary factory)

let print_cancellation candidate =
  let outcomes, stats, factory = run_effect (cancellation_smoke candidate) in
  let module P = (val candidate : CANDIDATE) in
  let render_outcome = function
    | Ok value -> "ok:" ^ value
    | Error (Cause.Fail Pool_shutdown) -> "error:pool_shutdown"
    | Error (Cause.Interrupt _) -> "error:interrupt"
    | Error cause ->
        Format.asprintf "error:%a"
          (Cause.pp (fun fmt -> function
            | Pool_shutdown -> Format.pp_print_string fmt "Pool_shutdown"
            | Connect_failed msg -> Format.fprintf fmt "Connect_failed(%s)" msg
            | Release_failed msg -> Format.fprintf fmt "Release_failed(%s)" msg))
          cause
  in
  Printf.printf "cancellation_smoke candidate=%s outcomes=%s %s %s\n%!"
    P.label (String.concat "," (List.map render_outcome outcomes))
    (stats_summary stats) (factory_summary factory)

let print_idle_eviction candidate =
  let stats, factory = run_effect (idle_eviction_smoke candidate) in
  let module P = (val candidate : CANDIDATE) in
  Printf.printf "idle_eviction_smoke candidate=%s %s %s\n%!" P.label
    (stats_summary stats) (factory_summary factory)

let () =
  List.iter (measure_effect "protocol_churn" protocol_churn) candidates;
  List.iter (measure_effect "protocol_warm_cache" protocol_warm_cache) candidates;
  List.iter print_cancellation candidates;
  List.iter print_idle_eviction candidates
