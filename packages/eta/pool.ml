type stats = {
  active : int;
  idle : int;
  waiting : int;
  max_size : int;
  opened : int;
  closed : int;
  health_rejected : int;
  cancelled_waiters : int;
  shutting_down : bool;
}

type 'conn entry = {
  conn : 'conn;
  created_ms : int;
  mutable last_used_ms : int;
}

type ('conn, 'err) t = {
  name : string;
  kind : string option;
  attrs : (string * string) list;
  max_size : int;
  max_idle : int;
  idle_lifetime : Duration.t option;
  max_lifetime : Duration.t option;
  expires_entries : bool;
  idle_check_interval : Duration.t;
  acquire_conn : ('conn, 'err) Effect.t;
  release_conn : 'conn -> (unit, 'err) Effect.t;
  health_check : 'conn -> (unit, 'err) Effect.t;
  mutex : Eio.Mutex.t;
  sem : Semaphore.t;
  mutable idle : 'conn entry list;
  mutable idle_count : int;
  mutable total : int;
  mutable active : int;
  mutable opened : int;
  mutable closed : int;
  mutable health_rejected : int;
  mutable shutting_down : bool;
}

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let duration_expired ~now duration started_at =
  now - started_at >= Duration.to_ms duration

let make_attrs name kind =
  match kind with
  | None -> [ ("eta.pool.name", name) ]
  | Some kind -> [ ("eta.pool.name", name); ("eta.pool.kind", kind) ]

let attrs t = t.attrs

let span t name e =
  Effect.Private.named_attrs ~kind:Capabilities.Internal name ~attrs:t.attrs e

let log t ?(level = Capabilities.Debug) body =
  Effect.log ~level ~attrs:(attrs t) body

let metric_int t ~name ~kind ~unit_ value =
  Effect.Private.metric_updates_lazy (fun () ->
      [ (name, "", unit_, kind, t.attrs, Capabilities.Int (value ())) ])

let metric_float t ~name ~kind ~unit_ value =
  Effect.Private.metric_updates_lazy (fun () ->
      [ (name, "", unit_, kind, t.attrs, Capabilities.Float (value ())) ])

let stats_locked t =
  {
    active = t.active;
    idle = t.idle_count;
    waiting = Semaphore.waiting t.sem;
    max_size = t.max_size;
    opened = t.opened;
    closed = t.closed;
    health_rejected = t.health_rejected;
    cancelled_waiters = Semaphore.cancelled_waiters t.sem;
    shutting_down = t.shutting_down;
  }

let emit_gauges t =
  Effect.Private.metric_updates_lazy (fun () ->
      let s = Eio.Mutex.use_ro t.mutex @@ fun () -> stats_locked t in
      [
        ( "eta.pool.active",
          "",
          "{connection}",
          Capabilities.Gauge,
          t.attrs,
          Capabilities.Int s.active );
        ( "eta.pool.idle",
          "",
          "{connection}",
          Capabilities.Gauge,
          t.attrs,
          Capabilities.Int s.idle );
        ( "eta.pool.waiting",
          "",
          "{waiter}",
          Capabilities.Gauge,
          t.attrs,
          Capabilities.Int s.waiting );
        ( "eta.pool.max_size",
          "",
          "{connection}",
          Capabilities.Gauge,
          t.attrs,
          Capabilities.Int s.max_size );
      ])

let emit_opened t =
  metric_int t ~name:"eta.pool.opened"
    ~kind:Capabilities.Counter_monotonic ~unit_:"{connection}" (fun () ->
      Eio.Mutex.use_ro t.mutex @@ fun () -> t.opened)

let emit_closed t =
  metric_int t ~name:"eta.pool.closed"
    ~kind:Capabilities.Counter_monotonic ~unit_:"{connection}" (fun () ->
      Eio.Mutex.use_ro t.mutex @@ fun () -> t.closed)

let emit_health_rejected t =
  metric_int t ~name:"eta.pool.health_rejected"
    ~kind:Capabilities.Counter_monotonic ~unit_:"{connection}" (fun () ->
      Eio.Mutex.use_ro t.mutex @@ fun () -> t.health_rejected)

let emit_cancelled_waiters t =
  metric_int t ~name:"eta.pool.cancelled_waiters"
    ~kind:Capabilities.Counter_monotonic ~unit_:"{waiter}" (fun () ->
      Semaphore.cancelled_waiters t.sem)

let emit_wait_ms t started_ms =
  metric_float t ~name:"eta.pool.acquire_wait_ms"
    ~kind:Capabilities.Counter_cumulative ~unit_:"ms" (fun () ->
      float_of_int (max 0 (now_ms () - started_ms)))

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let is_expired t now entry =
  match t.max_lifetime with
  | Some max_lifetime when duration_expired ~now max_lifetime entry.created_ms ->
      true
  | _ -> (
      match t.idle_lifetime with
      | Some idle_lifetime ->
          duration_expired ~now idle_lifetime entry.last_used_ms
      | None -> false)

let take_expired_idle_locked t =
  let now = now_ms () in
  let rec split expired keep keep_count = function
    | [] -> (List.rev expired, List.rev keep, keep_count)
    | entry :: rest ->
        if is_expired t now entry then
          split (entry :: expired) keep keep_count rest
        else split expired (entry :: keep) (keep_count + 1) rest
  in
  let expired, keep, keep_count = split [] [] 0 t.idle in
  t.idle <- keep;
  t.idle_count <- keep_count;
  expired

type 'conn reservation =
  [ `Close_expired of 'conn entry list
  | `Open_new
  | `Shutdown
  | `Use of 'conn entry
  | `Wait
  ]

let reserve t =
  with_lock t @@ fun () ->
  if t.shutting_down then (
    Semaphore.release t.sem 1;
    `Shutdown)
  else
    let expired = if t.expires_entries then take_expired_idle_locked t else [] in
    match expired with
    | _ :: _ -> `Close_expired expired
    | [] -> (
        match t.idle with
        | entry :: rest ->
            t.idle <- rest;
            t.idle_count <- t.idle_count - 1;
            t.active <- t.active + 1;
            `Use entry
        | [] when t.total < t.max_size ->
            t.total <- t.total + 1;
            t.active <- t.active + 1;
            `Open_new
        | [] ->
            Semaphore.release t.sem 1;
            `Wait)

let mark_open_failed t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  t.active <- max 0 (t.active - 1);
  t.total <- max 0 (t.total - 1);
  Semaphore.release t.sem 1

let mark_opened t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () -> t.opened <- t.opened + 1

let mark_health_rejected t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () -> t.health_rejected <- t.health_rejected + 1

let mark_closed ?(release_permit = true) t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  t.total <- max 0 (t.total - 1);
  t.closed <- t.closed + 1;
  if release_permit then Semaphore.release t.sem 1

let close_entry ?(release_permit = true) t entry =
  let close_once =
    span t "eta.pool.close"
      (t.release_conn entry.conn
      |> Effect.map (fun () -> `Closed)
      |> Effect.catch (fun err ->
             log t ~level:Capabilities.Warn "eta.pool.close_failed"
             |> Effect.map (fun () -> `Close_failed err)))
  in
  close_once
  |> Effect.bind (fun result ->
         mark_closed ~release_permit t
         |> Effect.bind (fun () -> emit_closed t)
         |> Effect.bind (fun () -> emit_gauges t)
         |> Effect.bind (fun () ->
                match result with
                | `Closed -> Effect.unit
                | `Close_failed err -> Effect.fail err))

let close_entries ?(release_permit = true) t entries =
  entries |> List.map (close_entry ~release_permit t) |> Effect.concat

let mark_released_to_close t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () -> t.active <- max 0 (t.active - 1)

let release_entry t entry =
  let decide =
    Effect.sync @@ fun () ->
    let now = if t.expires_entries then now_ms () else 0 in
    with_lock t @@ fun () ->
    let close =
      t.shutting_down
      || (
           t.expires_entries
           &&
           match t.max_lifetime with
           | Some max_lifetime ->
               duration_expired ~now max_lifetime entry.created_ms
           | None -> false)
    in
    if close || t.idle_count >= t.max_idle then (
      t.active <- max 0 (t.active - 1);
      `Close)
    else (
      entry.last_used_ms <- now;
      t.active <- max 0 (t.active - 1);
      t.idle <- entry :: t.idle;
      t.idle_count <- t.idle_count + 1;
      `Keep)
  in
  decide
  |> Effect.bind (function
       | `Keep ->
           Semaphore.release t.sem 1;
           emit_gauges t
       | `Close ->
           emit_gauges t
           |> Effect.bind (fun () -> close_entry t entry))

let reject_entry t entry =
  mark_health_rejected t
  |> Effect.bind (fun () -> log t "eta.pool.health_rejected")
  |> Effect.bind (fun () -> emit_health_rejected t)
  |> Effect.bind (fun () -> emit_gauges t)
  |> Effect.bind (fun () -> mark_released_to_close t)
  |> Effect.bind (fun () -> close_entry t entry)

let check_health t entry =
  span t "eta.pool.health_check" (t.health_check entry.conn)
  |> Effect.map (fun () -> `Healthy entry)
  |> Effect.catch (fun _ -> Effect.pure (`Rejected entry))

let make_entry t conn =
  let now = if t.expires_entries then now_ms () else 0 in
  { conn; created_ms = now; last_used_ms = now }

let with_acquire_guard release f =
  let armed = ref true in
  let release_ref = ref release in
  let disarm () = armed := false in
  let set_release release = release_ref := release in
  let release () = if !armed then !release_ref () else Effect.unit in
  Effect.scoped
    (Effect.acquire_release ~acquire:Effect.unit ~release
    |> Effect.bind (fun () -> f ~disarm ~set_release))

let with_fixed_acquire_guard release f =
  let armed = ref true in
  let disarm () = armed := false in
  let release () = if !armed then release () else Effect.unit in
  Effect.scoped
    (Effect.acquire_release ~acquire:Effect.unit ~release
    |> Effect.bind (fun () -> f ~disarm))

let close_acquired_entry t entry =
  mark_released_to_close t |> Effect.bind (fun () -> close_entry t entry)

let rec acquire_entry t =
  let use_entry entry =
    with_fixed_acquire_guard
      (fun () -> close_acquired_entry t entry)
      (fun ~disarm ->
        let after_health = function
          | `Healthy entry ->
              disarm ();
              emit_gauges t |> Effect.map (fun () -> entry)
          | `Rejected entry ->
              disarm ();
              reject_entry t entry |> Effect.bind (fun () -> acquire_entry t)
        in
        check_health t entry |> Effect.bind after_health)
  in
  let after_open ~disarm ~set_release conn =
    let entry = make_entry t conn in
    set_release (fun () -> close_acquired_entry t entry);
    let after_health = function
      | `Healthy entry ->
          disarm ();
          emit_gauges t |> Effect.map (fun () -> entry)
      | `Rejected entry ->
          disarm ();
          reject_entry t entry |> Effect.bind (fun () -> acquire_entry t)
    in
    mark_opened t
    |> Effect.bind (fun () -> emit_opened t)
    |> Effect.bind (fun () -> emit_gauges t)
    |> Effect.bind (fun () -> check_health t entry)
    |> Effect.bind after_health
  in
  let open_new =
    with_acquire_guard
      (fun () -> mark_open_failed t |> Effect.bind (fun () -> emit_gauges t))
      (fun ~disarm ~set_release ->
        t.acquire_conn
        |> Effect.bind (after_open ~disarm ~set_release))
  in
  Semaphore.acquire t.sem 1
  |> Effect.bind (fun () ->
       let rec try_reserve () =
         Effect.sync (fun () -> reserve t)
         |> Effect.bind (function
              | `Shutdown -> Effect.fail `Pool_shutdown
              | `Wait ->
                  Semaphore.acquire t.sem 1
                  |> Effect.bind (fun () -> try_reserve ())
              | `Close_expired expired ->
                  close_entries ~release_permit:false t expired
                  |> Effect.bind (fun () -> try_reserve ())
              | `Use entry -> use_entry entry
              | `Open_new -> open_new)
       in
       try_reserve ())

let with_resource t body =
  Effect.scoped
    (Effect.acquire_release
       ~acquire:(span t "eta.pool.acquire" (acquire_entry t))
       ~release:(release_entry t)
    |> Effect.bind (fun entry -> body entry.conn))

let evict_idle_once t =
  let expired =
    Effect.sync @@ fun () ->
    with_lock t @@ fun () ->
    if t.shutting_down then [] else take_expired_idle_locked t
  in
  expired |> Effect.bind (close_entries ~release_permit:false t)

let rec eviction_loop t =
  Effect.delay t.idle_check_interval (evict_idle_once t)
  |> Effect.bind (fun () ->
         if Eio.Mutex.use_ro t.mutex (fun () -> t.shutting_down) then
           Effect.unit
         else eviction_loop t)

let validate ~max_size ~max_idle ~idle_check_interval =
  if max_size <= 0 then invalid_arg "Eta.Pool.create: max_size must be > 0";
  if max_idle < 0 then invalid_arg "Eta.Pool.create: max_idle must be >= 0";
  if max_idle > max_size then
    invalid_arg "Eta.Pool.create: max_idle must be <= max_size";
  if Duration.to_ms idle_check_interval <= 0 then
    invalid_arg "Eta.Pool.create: idle_check_interval must be > 0"

let create ?(name = "eta.pool") ?kind ~max_size ?max_idle ?idle_lifetime
    ?max_lifetime ?(idle_check_interval = Duration.seconds 1) ~acquire ~release
    ?health_check () =
  let max_idle = Option.value max_idle ~default:max_size in
  validate ~max_size ~max_idle ~idle_check_interval;
  let health_check =
    Option.value health_check ~default:(fun _ -> Effect.unit)
  in
  let t =
    {
      name;
      kind;
      attrs = make_attrs name kind;
      max_size;
      max_idle;
      idle_lifetime;
      max_lifetime;
      expires_entries = Option.is_some idle_lifetime || Option.is_some max_lifetime;
      idle_check_interval;
      acquire_conn = acquire;
      release_conn = release;
      health_check;
      mutex = Eio.Mutex.create ();
      sem = Semaphore.make ~permits:max_size;
      idle = [];
      idle_count = 0;
      total = 0;
      active = 0;
      opened = 0;
      closed = 0;
      health_rejected = 0;
      shutting_down = false;
    }
  in
  let start_daemon =
    match (idle_lifetime, max_lifetime) with
    | None, None -> Effect.unit
    | Some _, _ | _, Some _ -> Effect.Private.daemon (eviction_loop t)
  in
  start_daemon |> Effect.map (fun () -> t)

let rec wait_until_drained t =
  Effect.sync
    (fun () -> Eio.Mutex.use_ro t.mutex @@ fun () -> t.active = 0)
  |> Effect.bind (function
       | true -> Effect.unit
       | false ->
           Effect.delay (Duration.ms 1) Effect.unit
           |> Effect.bind (fun () -> wait_until_drained t))

let begin_shutdown t =
  let take_idle =
    Effect.sync @@ fun () ->
    with_lock t @@ fun () ->
    if not t.shutting_down then t.shutting_down <- true;
    let idle = t.idle in
    t.idle <- [];
    t.idle_count <- 0;
    idle
  in
  log t ~level:Capabilities.Info "eta.pool.shutdown_started"
  |> Effect.bind (fun () -> take_idle)
  |> Effect.bind (close_entries ~release_permit:false t)
  |> Effect.bind (fun () ->
       Effect.sync (fun () -> Semaphore.release t.sem t.max_size))
  |> Effect.bind (fun () -> emit_gauges t)

let shutdown ?deadline t =
  let drain =
    begin_shutdown t
    |> Effect.bind (fun () -> wait_until_drained t)
  in
  let with_deadline =
    match deadline with
    | None -> drain
    | Some deadline ->
        Effect.timeout_as deadline ~on_timeout:`Pool_shutdown_timeout drain
        |> Effect.catch (function
             | `Pool_shutdown_timeout ->
                 log t ~level:Capabilities.Warn "eta.pool.shutdown_timeout"
                 |> Effect.bind (fun () -> Effect.fail `Pool_shutdown_timeout)
             | err -> Effect.fail err)
  in
  span t "eta.pool.shutdown" with_deadline

let stats t = Eio.Mutex.use_ro t.mutex @@ fun () -> stats_locked t
