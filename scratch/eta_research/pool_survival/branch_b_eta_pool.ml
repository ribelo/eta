open Eta
open Common

type 'conn config = {
  max_size : int;
  max_idle : int;
  idle_lifetime : Duration.t option;
  max_lifetime : Duration.t option;
  health_check : 'conn -> bool;
}

type 'conn entry = {
  conn : 'conn;
  created_ms : int;
  mutable last_used_ms : int;
}

type 'conn t = {
  config : 'conn config;
  acquire_conn : ('conn, error) Effect.t;
  release_conn : 'conn -> (unit, error) Effect.t;
  id : 'conn -> int;
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
  events : string Eio.Stream.t;
  mutable idle : 'conn entry list;
  mutable total : int;
  mutable in_use : int;
  mutable waiting : int;
  mutable shutting_down : bool;
  mutable acquired : int;
  mutable opened_by_pool : int;
  mutable closed_by_pool : int;
  mutable health_rejected : int;
  mutable cancelled_waiters : int;
  mutable max_observed_in_use : int;
}

let emit t event = Eio.Stream.add t.events event

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  match f () with
  | value ->
      Eio.Mutex.unlock t.mutex;
      value
  | exception exn ->
      Eio.Mutex.unlock t.mutex;
      raise exn

let stats t =
  with_lock t @@ fun () ->
  {
    total = t.total;
    idle = List.length t.idle;
    in_use = t.in_use;
    waiting = t.waiting;
    max_size = t.config.max_size;
    acquired = t.acquired;
    opened_by_pool = t.opened_by_pool;
    closed_by_pool = t.closed_by_pool;
    health_rejected = t.health_rejected;
    cancelled_waiters = t.cancelled_waiters;
    max_observed_in_use = t.max_observed_in_use;
    shutting_down = t.shutting_down;
    events = Eio.Stream.length t.events;
  }

let validate_config (config : _ config) =
  if config.max_size <= 0 then invalid_arg "Eta.Pool: max_size must be > 0";
  if config.max_idle < 0 then invalid_arg "Eta.Pool: max_idle must be >= 0";
  if config.max_idle > config.max_size then
    invalid_arg "Eta.Pool: max_idle must be <= max_size"

let is_expired t now entry =
  match t.config.max_lifetime with
  | Some max_lifetime when duration_expired ~now max_lifetime entry.created_ms ->
      true
  | _ -> (
      match t.config.idle_lifetime with
      | Some idle_lifetime ->
          duration_expired ~now idle_lifetime entry.last_used_ms
      | None -> false)

let take_expired_idle_locked t =
  let now = now_ms () in
  let expired, keep = List.partition (is_expired t now) t.idle in
  if expired <> [] then (
    t.idle <- keep;
    t.total <- t.total - List.length expired;
    t.closed_by_pool <- t.closed_by_pool + List.length expired;
    List.iter
      (fun entry -> emit t ("idle_expired:" ^ string_of_int (t.id entry.conn)))
      expired);
  expired

let close_entries t entries =
  entries |> List.map (fun entry -> t.release_conn entry.conn) |> Effect.concat

type 'conn reservation =
  [ `Close_then_retry of 'conn entry list
  | `Open_new
  | `Shutdown
  | `Wait
  | `Use of 'conn entry
  ]

let reserve t =
  with_lock t @@ fun () ->
  if t.shutting_down then `Shutdown
  else
    let expired = take_expired_idle_locked t in
    if expired <> [] then `Close_then_retry expired
    else
      match t.idle with
      | entry :: rest ->
          t.idle <- rest;
          t.in_use <- t.in_use + 1;
          t.acquired <- t.acquired + 1;
          t.max_observed_in_use <- max t.max_observed_in_use t.in_use;
          emit t ("reuse:" ^ string_of_int (t.id entry.conn));
          `Use entry
      | [] when t.total < t.config.max_size ->
          t.total <- t.total + 1;
          t.in_use <- t.in_use + 1;
          t.opened_by_pool <- t.opened_by_pool + 1;
          t.max_observed_in_use <- max t.max_observed_in_use t.in_use;
          emit t "open_slot";
          `Open_new
      | [] -> `Wait

let wait_for_retry t =
  let completed = ref false in
  let register =
    Effect.named "eta_pool.wait_register" (Effect.sync (fun () ->
        with_lock t @@ fun () ->
        t.waiting <- t.waiting + 1;
        emit t "wait_register"))
  in
  let unregister () =
    Effect.named "eta_pool.wait_unregister" (Effect.sync (fun () ->
        with_lock t @@ fun () ->
        t.waiting <- max 0 (t.waiting - 1);
        if not !completed then (
          t.cancelled_waiters <- t.cancelled_waiters + 1;
          emit t "wait_cancelled")))
  in
  Effect.scoped
    (Effect.acquire_release ~acquire:register ~release:unregister
    |> Effect.bind (fun () ->
           Effect.delay (Duration.ms 1) Effect.unit
           |> Effect.map (fun () -> completed := true)))

let close_reserved t conn =
  let update =
    Effect.named "eta_pool.close_reserved" (Effect.sync (fun () ->
        with_lock t @@ fun () ->
        t.in_use <- max 0 (t.in_use - 1);
        t.total <- max 0 (t.total - 1);
        t.closed_by_pool <- t.closed_by_pool + 1;
        Eio.Condition.broadcast t.condition))
  in
  update |> Effect.bind (fun () -> t.release_conn conn)

let rec acquire_entry t =
  Effect.named "eta_pool.reserve" (Effect.sync (fun () -> reserve t))
  |> Effect.bind (function
       | `Shutdown -> Effect.fail `Pool_shutdown
       | `Wait -> wait_for_retry t |> Effect.bind (fun () -> acquire_entry t)
       | `Close_then_retry expired ->
           close_entries t expired |> Effect.bind (fun () -> acquire_entry t)
       | `Use entry ->
           if t.config.health_check entry.conn then Effect.pure entry
           else
             Effect.named "eta_pool.health_reject_reused" (Effect.sync (fun () ->
                 with_lock t @@ fun () ->
                 t.health_rejected <- t.health_rejected + 1))
             |> Effect.bind (fun () ->
                    close_reserved t entry.conn
                    |> Effect.bind (fun () -> acquire_entry t))
       | `Open_new ->
           t.acquire_conn
           |> Effect.catch (fun err ->
                  Effect.named "eta_pool.open_failed" (Effect.sync (fun () ->
                      with_lock t @@ fun () ->
                      t.in_use <- max 0 (t.in_use - 1);
                      t.total <- max 0 (t.total - 1);
                      Eio.Condition.broadcast t.condition))
                  |> Effect.bind (fun () -> Effect.fail err))
           |> Effect.bind (fun conn ->
                  let entry =
                    {
                      conn;
                      created_ms = now_ms ();
                      last_used_ms = now_ms ();
                    }
                  in
                  if t.config.health_check conn then
                    Effect.named "eta_pool.acquired_new" (Effect.sync (fun () ->
                        with_lock t @@ fun () -> t.acquired <- t.acquired + 1))
                    |> Effect.map (fun () -> entry)
                  else
                    Effect.named "eta_pool.health_reject_new" (Effect.sync (fun () ->
                        with_lock t @@ fun () ->
                        t.health_rejected <- t.health_rejected + 1))
                    |> Effect.bind (fun () ->
                           close_reserved t conn
                           |> Effect.bind (fun () -> acquire_entry t))))

let release_entry t entry =
  Effect.named "eta_pool.release_slot" (Effect.sync (fun () ->
      let now = now_ms () in
      with_lock t @@ fun () ->
      t.in_use <- max 0 (t.in_use - 1);
      let close =
        t.shutting_down
        || (match t.config.max_lifetime with
           | Some max_lifetime ->
               duration_expired ~now max_lifetime entry.created_ms
           | None -> false)
        || List.length t.idle >= t.config.max_idle
      in
      if close then (
        t.total <- max 0 (t.total - 1);
        t.closed_by_pool <- t.closed_by_pool + 1;
        emit t ("close:" ^ string_of_int (t.id entry.conn));
        Eio.Condition.broadcast t.condition;
        `Close entry.conn)
      else (
        entry.last_used_ms <- now;
        t.idle <- entry :: t.idle;
        emit t ("idle:" ^ string_of_int (t.id entry.conn));
        Eio.Condition.broadcast t.condition;
        `Keep)))
  |> Effect.bind (function
       | `Keep -> Effect.unit
       | `Close conn -> t.release_conn conn)

let with_resource t body =
  Effect.scoped
    (Effect.acquire_release ~acquire:(acquire_entry t) ~release:(release_entry t)
    |> Effect.bind (fun entry -> body entry.conn))

let rec eviction_loop t =
  Effect.delay (Duration.ms 1)
    (Effect.named "eta_pool.evict_idle" (Effect.sync (fun () ->
         with_lock t @@ fun () ->
         if t.shutting_down then []
         else
           let expired = take_expired_idle_locked t in
           Eio.Condition.broadcast t.condition;
           expired))
    |> Effect.bind (close_entries t))
  |> Effect.bind (fun () ->
         if (stats t).shutting_down then Effect.unit else eviction_loop t)

let create config ~id ~acquire ~release =
  validate_config config;
  let t =
    {
      config;
      acquire_conn = acquire;
      release_conn = release;
      id;
      mutex = Eio.Mutex.create ();
      condition = Eio.Condition.create ();
      events = Eio.Stream.create max_int;
      idle = [];
      total = 0;
      in_use = 0;
      waiting = 0;
      shutting_down = false;
      acquired = 0;
      opened_by_pool = 0;
      closed_by_pool = 0;
      health_rejected = 0;
      cancelled_waiters = 0;
      max_observed_in_use = 0;
    }
  in
  Effect.Private.daemon (eviction_loop t) |> Effect.map (fun () -> t)

let rec wait_until_drained t =
  Effect.named "eta_pool.wait_drain" (Effect.sync (fun () -> (stats t).in_use = 0))
  |> Effect.bind (function
       | true -> Effect.unit
       | false ->
           Effect.delay (Duration.ms 1) Effect.unit
           |> Effect.bind (fun () -> wait_until_drained t))

let shutdown ?deadline t =
  let begin_shutdown =
    Effect.named "eta_pool.shutdown_begin" (Effect.sync (fun () ->
        with_lock t @@ fun () ->
        t.shutting_down <- true;
        let idle = t.idle in
        t.idle <- [];
        t.total <- t.total - List.length idle;
        t.closed_by_pool <- t.closed_by_pool + List.length idle;
        emit t "shutdown_begin";
        Eio.Condition.broadcast t.condition;
        idle))
    |> Effect.bind (close_entries t)
  in
  let drain =
    begin_shutdown
    |> Effect.bind (fun () -> wait_until_drained t)
    |> Effect.bind (fun () ->
           Effect.named "eta_pool.shutdown_done" (Effect.sync (fun () -> emit t "shutdown_done")))
  in
  match deadline with
  | None -> drain
  | Some deadline -> Effect.timeout deadline drain

let create_for_fake ?(config = default_config) factory =
  create
    {
      max_size = config.max_size;
      max_idle = config.max_idle;
      idle_lifetime = config.idle_lifetime;
      max_lifetime = config.max_lifetime;
      health_check;
    }
    ~id:(fun conn -> conn.id)
    ~acquire:(open_connection factory)
    ~release:(close_connection factory)
