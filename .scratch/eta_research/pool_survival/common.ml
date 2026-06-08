open Eta

type error =
  [ `Pool_shutdown
  | `Timeout
  | `Connect_failed of string
  | `Release_failed of string
  ]

type pool_config = {
  max_size : int;
  max_idle : int;
  idle_lifetime : Duration.t option;
  max_lifetime : Duration.t option;
}

let default_config =
  {
    max_size = 8;
    max_idle = 8;
    idle_lifetime = Some (Duration.ms 50);
    max_lifetime = Some (Duration.seconds 1);
  }

type connection = {
  id : int;
  created_ms : int;
  closed : bool Atomic.t;
  unhealthy : bool Atomic.t;
  uses : int Atomic.t;
}

type factory = {
  next_id : int Atomic.t;
  opened : int Atomic.t;
  closed : int Atomic.t;
  live : int Atomic.t;
  max_live : int Atomic.t;
}

type factory_stats = {
  opened : int;
  closed : int;
  live : int;
  max_live : int;
}

type pool_stats = {
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
  shutting_down : bool;
  events : int;
}

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let atomic_incr cell =
  let rec loop () =
    let old = Atomic.get cell in
    if Atomic.compare_and_set cell old (old + 1) then old + 1 else loop ()
  in
  loop ()

let atomic_decr cell =
  let rec loop () =
    let old = Atomic.get cell in
    if Atomic.compare_and_set cell old (old - 1) then old - 1 else loop ()
  in
  loop ()

let atomic_update_max cell value =
  let rec loop () =
    let old = Atomic.get cell in
    if value <= old || Atomic.compare_and_set cell old value then () else loop ()
  in
  loop ()

let create_factory () =
  {
    next_id = Atomic.make 0;
    opened = Atomic.make 0;
    closed = Atomic.make 0;
    live = Atomic.make 0;
    max_live = Atomic.make 0;
  }

let factory_stats (factory : factory) =
  {
    opened = Atomic.get factory.opened;
    closed = Atomic.get factory.closed;
    live = Atomic.get factory.live;
    max_live = Atomic.get factory.max_live;
  }

let open_connection (factory : factory) =
  Effect.named "fake_connection.open" (Effect.sync (fun () ->
      let id = atomic_incr factory.next_id in
      ignore (atomic_incr factory.opened : int);
      let live = atomic_incr factory.live in
      atomic_update_max factory.max_live live;
      {
        id;
        created_ms = now_ms ();
        closed = Atomic.make false;
        unhealthy = Atomic.make (id = 3);
        uses = Atomic.make 0;
      }))

let close_connection (factory : factory) (conn : connection) =
  Effect.named "fake_connection.close" (Effect.sync (fun () ->
      if Atomic.compare_and_set conn.closed false true then (
        ignore (atomic_incr factory.closed : int);
        ignore (atomic_decr factory.live : int))))

let health_check (conn : connection) =
  (not (Atomic.get conn.closed)) && not (Atomic.get conn.unhealthy)

let use_connection (conn : connection) =
  Effect.named "fake_connection.use" (Effect.sync (fun () ->
      if Atomic.get conn.closed then
        failwith (Printf.sprintf "connection %d used after close" conn.id);
      ignore (atomic_incr conn.uses : int)))

let duration_expired ~now duration started_at =
  now - started_at >= Duration.to_ms duration

let pp_factory_stats (stats : factory_stats) =
  Printf.sprintf "opened=%d closed=%d live=%d max_live=%d" stats.opened
    stats.closed stats.live stats.max_live

let pp_pool_stats (stats : pool_stats) =
  Printf.sprintf
    "total=%d idle=%d in_use=%d waiting=%d max_size=%d acquired=%d opened_by_pool=%d closed_by_pool=%d health_rejected=%d cancelled_waiters=%d max_observed_in_use=%d shutting_down=%b events=%d"
    stats.total stats.idle stats.in_use stats.waiting stats.max_size
    stats.acquired stats.opened_by_pool stats.closed_by_pool
    stats.health_rejected stats.cancelled_waiters stats.max_observed_in_use
    stats.shutting_down stats.events

let check label condition =
  if not condition then failwith ("pool_survival: " ^ label)

let list_init n f = List.init n f
