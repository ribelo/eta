(* Pool state transitions and counters must move together under the same
   lifecycle authority. *)

type stats : immutable_data = {
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
  release_conn : ('conn -> (unit, 'err) Effect.t) @@ many;
  health_check : ('conn -> (unit, 'err) Effect.t) @@ many;
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
  shutdown_requested : unit Eio.Promise.t;
  shutdown_resolver : unit Eio.Promise.u;
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
  Effect.named_kind ~kind:Capabilities.Internal name
    (Effect.annotate_all t.attrs e)

let log t ?(level = Capabilities.Debug) body =
  Effect.log ~level ~attrs:(attrs t) body

let metric_int t ~name ~kind ~unit_ value =
  Effect.sync value
  |> Effect.bind (fun value ->
         Effect.metric_update ~attrs:t.attrs ~name ~kind ~unit_
           (Capabilities.Int value))

let metric_float t ~name ~kind ~unit_ value =
  Effect.sync value
  |> Effect.bind (fun value ->
         Effect.metric_update ~attrs:t.attrs ~name ~kind ~unit_
           (Capabilities.Float value))

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
  Effect.sync (fun () -> Eio.Mutex.use_ro t.mutex @@ fun () -> stats_locked t)
  |> Effect.bind (fun (s : stats) ->
         Effect.all
           [
             Effect.metric_update ~attrs:t.attrs ~name:"eta.pool.active"
               ~kind:Capabilities.Gauge ~unit_:"{connection}"
               (Capabilities.Int s.active);
             Effect.metric_update ~attrs:t.attrs ~name:"eta.pool.idle"
               ~kind:Capabilities.Gauge ~unit_:"{connection}"
               (Capabilities.Int s.idle);
             Effect.metric_update ~attrs:t.attrs ~name:"eta.pool.waiting"
               ~kind:Capabilities.Gauge ~unit_:"{waiter}"
               (Capabilities.Int s.waiting);
             Effect.metric_update ~attrs:t.attrs ~name:"eta.pool.max_size"
               ~kind:Capabilities.Gauge ~unit_:"{connection}"
               (Capabilities.Int s.max_size);
           ])
  |> Effect.map ignore

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

let invariant_violation field =
  invalid_arg ("Eta.Pool invariant violated: " ^ field ^ " underflow")

let decr_active_locked t =
  if t.active <= 0 then invariant_violation "active";
  t.active <- t.active - 1

let decr_total_locked t =
  if t.total <= 0 then invariant_violation "total";
  t.total <- t.total - 1

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
  if t.shutting_down then `Shutdown
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
        | [] -> `Wait)

let wait_for_shutdown t =
  Effect.sync (fun () -> Eio.Promise.await t.shutdown_requested)

let mark_open_failed t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  decr_active_locked t;
  decr_total_locked t

let mark_opened t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () -> t.opened <- t.opened + 1

let mark_health_rejected t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () -> t.health_rejected <- t.health_rejected + 1

let mark_closed ?(release_permit = true) t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  decr_total_locked t;
  t.closed <- t.closed + 1;
  if release_permit then Semaphore.release t.sem 1

let close_entry_once t entry =
  span t "eta.pool.close"
    (t.release_conn entry.conn
    |> Effect.map (fun () -> `Closed)
    |> Effect.catch (fun err ->
           log t ~level:Capabilities.Warn "eta.pool.close_failed"
           |> Effect.map (fun () -> `Close_failed err)))

let finish_close = function
  | `Closed -> Effect.unit
  | `Close_failed err -> Effect.fail err

let close_entry ?(release_permit = true) t entry =
  let mark_close_finished =
    mark_closed ~release_permit t
    |> Effect.bind (fun () -> emit_closed t)
    |> Effect.bind (fun () -> emit_gauges t)
  in
  close_entry_once t entry
  |> Effect.finally mark_close_finished
  |> Effect.bind finish_close

let remove_idle_entry_locked t entry =
  let rec remove acc = function
    | [] -> (false, List.rev acc)
    | candidate :: rest when candidate == entry ->
        (true, List.rev_append acc rest)
    | candidate :: rest -> remove (candidate :: acc) rest
  in
  let removed, idle = remove [] t.idle in
  if removed then (
    if t.idle_count <= 0 then invariant_violation "idle";
    t.idle <- idle;
    t.idle_count <- t.idle_count - 1);
  removed

let mark_idle_closed t entry =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  let removed = remove_idle_entry_locked t entry in
  if removed then (
    decr_total_locked t;
    t.closed <- t.closed + 1);
  removed

let close_idle_entry t entry =
  close_entry_once t entry
  |> Effect.bind (fun result ->
         mark_idle_closed t entry
         |> Effect.bind (function
              | true ->
                  emit_closed t
                  |> Effect.bind (fun () -> emit_gauges t)
                  |> Effect.bind (fun () -> finish_close result)
              | false -> emit_gauges t |> Effect.bind (fun () -> finish_close result)))

exception Close_entries_failed of string

type 'err close_entries_failure =
  | Close_typed of 'err
  | Close_cause of 'err Cause.t

let first_close_failure results =
  let rec loop = function
    | [] -> None
    | Ok () :: rest -> loop rest
    | Error (Cause.Fail err) :: _ -> Some (Close_typed err)
    | Error cause :: _ -> Some (Close_cause cause)
  in
  loop results

let fail_close_cause cause =
  Effect.sync @@ fun () ->
  let message =
    Format.asprintf "Eta.Pool.close_entries: %a"
      (Cause.pp (fun ppf _ ->
           Format.pp_print_string ppf "<pool release failure>"))
      cause
  in
  raise (Close_entries_failed message)

let close_entries_with close entries =
  entries
  |> List.map close
  |> Effect.all_settled
  |> Effect.bind (fun results ->
         match first_close_failure results with
         | None -> Effect.unit
         | Some (Close_typed err) -> Effect.fail err
         | Some (Close_cause cause) -> fail_close_cause cause)

let close_entries ?(release_permit = true) t entries =
  close_entries_with (close_entry ~release_permit t) entries

let close_entries_for_eviction t entries =
  entries
  |> List.map (close_entry ~release_permit:false t)
  |> Effect.all_settled
  |> Effect.bind (fun results ->
         match first_close_failure results with
         | None -> Effect.unit
         | Some _ ->
             log t ~level:Capabilities.Warn
               "eta.pool.eviction_close_failed")

let close_idle_entries t entries = close_entries_with (close_idle_entry t) entries

let mark_released_to_close t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () -> decr_active_locked t

let mark_active_close_finished t =
  mark_released_to_close t |> Effect.bind (fun () -> emit_gauges t)

let release_entry ?(release_permit = true) t entry =
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
    if close || t.idle_count >= t.max_idle then `Close
    else (
      entry.last_used_ms <- now;
      decr_active_locked t;
      t.idle <- entry :: t.idle;
      t.idle_count <- t.idle_count + 1;
      `Keep)
  in
  decide
  |> Effect.bind (function
       | `Keep ->
           if release_permit then Semaphore.release t.sem 1;
           emit_gauges t
       | `Close ->
           emit_gauges t
           |> Effect.bind (fun () ->
                  close_entry ~release_permit t entry
                  |> Effect.finally (mark_active_close_finished t)))

let reject_entry ?(release_permit = true) t entry =
  mark_health_rejected t
  |> Effect.bind (fun () -> log t "eta.pool.health_rejected")
  |> Effect.bind (fun () -> emit_health_rejected t)
  |> Effect.bind (fun () -> emit_gauges t)
  |> Effect.bind (fun () ->
         close_entry ~release_permit t entry
         |> Effect.finally (mark_active_close_finished t))

let check_health t entry =
  span t "eta.pool.health_check" (t.health_check entry.conn)
  |> Effect.map (fun () -> `Healthy entry)
  |> Effect.catch (fun _ -> Effect.pure (`Rejected entry))

let make_entry t conn =
  let now = if t.expires_entries then now_ms () else 0 in
  { conn; created_ms = now; last_used_ms = now }

type 'conn acquisition_state =
  | Reserve_slot
  | Close_expired_entries of 'conn entry list
  | Check_reserved_entry of 'conn entry
  | Open_entry
  | Entry_acquired of 'conn entry

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
  close_entry ~release_permit:false t entry
  |> Effect.finally (mark_active_close_finished t)

let close_expired_entries_before_retry t entries =
  close_entries ~release_permit:false t entries
  |> Effect.map (fun () -> Reserve_slot)

let state_of_reservation = function
  | `Shutdown -> Effect.fail `Pool_shutdown
  | `Wait ->
      Effect.sync (fun () ->
          invalid_arg
            "Eta.Pool invariant violated: admitted checkout had no reservable slot")
  | `Close_expired entries -> Effect.pure (Close_expired_entries entries)
  | `Use entry -> Effect.pure (Check_reserved_entry entry)
  | `Open_new -> Effect.pure Open_entry

let health_transition t ~disarm = function
  | `Healthy entry ->
      disarm ();
      emit_gauges t |> Effect.map (fun () -> Entry_acquired entry)
  | `Rejected entry ->
      disarm ();
      reject_entry ~release_permit:false t entry
      |> Effect.map (fun () -> Reserve_slot)

let check_reserved_entry t entry =
  with_fixed_acquire_guard
    (fun () -> close_acquired_entry t entry)
    (fun ~disarm ->
      check_health t entry |> Effect.bind (health_transition t ~disarm))

let open_entry t =
  let release_on_open_failure () =
    mark_open_failed t |> Effect.bind (fun () -> emit_gauges t)
  in
  let after_open ~disarm ~set_release conn =
    let entry = make_entry t conn in
    set_release (fun () -> close_acquired_entry t entry);
    mark_opened t
    |> Effect.bind (fun () -> emit_opened t)
    |> Effect.bind (fun () -> emit_gauges t)
    |> Effect.bind (fun () -> check_health t entry)
    |> Effect.bind (health_transition t ~disarm)
  in
  with_acquire_guard release_on_open_failure (fun ~disarm ~set_release ->
      t.acquire_conn |> Effect.bind (after_open ~disarm ~set_release))

let next_state t = function
  | Reserve_slot ->
      Effect.sync (fun () -> reserve t) |> Effect.bind state_of_reservation
  | Close_expired_entries entries ->
      close_expired_entries_before_retry t entries
  | Check_reserved_entry entry -> check_reserved_entry t entry
  | Open_entry -> open_entry t
  | Entry_acquired _ as state -> Effect.pure state

let rec run_acquisition t state =
  next_state t state
  |> Effect.bind (function
       | Entry_acquired entry -> Effect.pure entry
       | next -> run_acquisition t next)

let acquire_entry t = run_acquisition t Reserve_slot

let with_resource t body =
  let checkout =
    Effect.scoped
      (Effect.acquire_release
         ~acquire:(span t "eta.pool.acquire" (acquire_entry t))
         ~release:(release_entry ~release_permit:false t)
      |> Effect.bind (fun entry -> body entry.conn))
  in
  Effect.sync (fun () -> Eio.Mutex.use_ro t.mutex (fun () -> t.shutting_down))
  |> Effect.bind (function
       | true -> Effect.fail `Pool_shutdown
       | false ->
           Semaphore.with_permits_or_abort t.sem 1
             ~abort:(wait_for_shutdown t) (fun () -> checkout)
           |> Effect.bind (function
                | Some value -> Effect.pure value
                | None -> Effect.fail `Pool_shutdown))

let evict_idle_once t =
  let expired =
    Effect.sync @@ fun () ->
    with_lock t @@ fun () ->
    if t.shutting_down then [] else take_expired_idle_locked t
  in
  expired |> Effect.bind (close_entries_for_eviction t)

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
    ?max_lifetime ?(idle_check_interval = Duration.seconds 1) ~acquire
    ~(release @ many) ?(health_check @ many = fun _ -> Effect.unit) () =
  let max_idle = Option.value max_idle ~default:max_size in
  validate ~max_size ~max_idle ~idle_check_interval;
  let shutdown_requested, shutdown_resolver = Eio.Promise.create () in
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
      shutdown_requested;
      shutdown_resolver;
    }
  in
  let start_daemon =
    match (idle_lifetime, max_lifetime) with
    | None, None -> Effect.unit
    | Some _, _ | _, Some _ -> Effect.daemon (eviction_loop t)
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
  let snapshot_idle =
    Effect.sync @@ fun () ->
    with_lock t @@ fun () ->
    if not t.shutting_down then (
      t.shutting_down <- true;
      if not (Eio.Promise.is_resolved t.shutdown_requested) then
        Eio.Promise.resolve t.shutdown_resolver ());
    t.idle
  in
  log t ~level:Capabilities.Info "eta.pool.shutdown_started"
  |> Effect.bind (fun () -> snapshot_idle)
  |> Effect.bind (close_idle_entries t)
  |> Effect.bind (fun () -> emit_gauges t)

let shutdown ?deadline t =
  let drain = wait_until_drained t in
  let with_deadline =
    match deadline with
    | None -> drain
    | Some deadline ->
        (* The deadline only bounds checked-out resources draining. Idle
           resources are already under the pool's close fence; canceling that
           release path would make accounting claim a close that did not
           finish. *)
        Effect.timeout_as deadline ~on_timeout:`Pool_shutdown_timeout drain
        |> Effect.catch (function
             | `Pool_shutdown_timeout ->
                 log t ~level:Capabilities.Warn "eta.pool.shutdown_timeout"
                 |> Effect.bind (fun () -> Effect.fail `Pool_shutdown_timeout)
             | err -> Effect.fail err)
  in
  span t "eta.pool.shutdown" (begin_shutdown t |> Effect.bind (fun () -> with_deadline))

let stats t = Eio.Mutex.use_ro t.mutex @@ fun () -> stats_locked t
