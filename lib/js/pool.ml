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

type drain_waiter = {
  mutable active : bool;
  resume : unit -> unit;
}

type shutdown_waiter = {
  mutable active : bool;
  resume : unit -> unit;
}

type ('conn, 'err) t = {
  name : string;
  kind : string option;
  max_size : int;
  max_idle : int;
  idle_lifetime : Duration.t option;
  max_lifetime : Duration.t option;
  expires_entries : bool;
  idle_check_interval : Duration.t;
  acquire_conn : ('conn, 'err) Effect.t;
  release_conn : 'conn -> (unit, 'err) Effect.t;
  health_check : 'conn -> (unit, 'err) Effect.t;
  sem : Semaphore.t;
  mutable idle : 'conn entry list;
  mutable idle_count : int;
  mutable total : int;
  mutable active : int;
  mutable opened : int;
  mutable closed : int;
  mutable health_rejected : int;
  mutable shutting_down : bool;
  mutable drain_waiters : drain_waiter list;
  mutable shutdown_waiters : shutdown_waiter list;
}

let now_ms () = int_of_float (Js_interop.date_now ())

let duration_expired ~now duration started_at =
  now - started_at >= Duration.to_ms duration

let is_expired t now entry =
  match t.max_lifetime with
  | Some max_lifetime when duration_expired ~now max_lifetime entry.created_ms ->
      true
  | _ -> (
      match t.idle_lifetime with
      | Some idle_lifetime ->
          duration_expired ~now idle_lifetime entry.last_used_ms
      | None -> false)

let wake_drain_waiters t =
  if t.active = 0 then begin
    let waiters = List.rev t.drain_waiters in
    t.drain_waiters <- [];
    List.iter
      (fun (waiter : drain_waiter) ->
        if waiter.active then waiter.resume ())
      waiters
  end

let wake_shutdown_waiters t =
  let waiters = List.rev t.shutdown_waiters in
  t.shutdown_waiters <- [];
  List.iter
    (fun (waiter : shutdown_waiter) ->
      if waiter.active then waiter.resume ())
    waiters

let mark_active_finished t =
  if t.active <= 0 then
    invalid_arg "Eta_js.Pool invariant violated: active underflow";
  t.active <- t.active - 1;
  wake_drain_waiters t

let mark_closed t =
  if t.total <= 0 then
    invalid_arg "Eta_js.Pool invariant violated: total underflow";
  t.total <- t.total - 1;
  t.closed <- t.closed + 1

let make_entry conn =
  let now = now_ms () in
  { conn; created_ms = now; last_used_ms = now }

let validate ~max_size ~max_idle ~idle_check_interval =
  if max_size <= 0 then invalid_arg "Eta_js.Pool.create: max_size must be > 0";
  if max_idle < 0 then invalid_arg "Eta_js.Pool.create: max_idle must be >= 0";
  if max_idle > max_size then
    invalid_arg "Eta_js.Pool.create: max_idle must be <= max_size";
  if Duration.is_zero idle_check_interval then
    invalid_arg "Eta_js.Pool.create: idle_check_interval must be > 0"

type 'conn reservation =
  | Shutdown
  | Use of 'conn entry
  | Open_new

let take_expired_idle t =
  let now = now_ms () in
  let rec split expired keep keep_count = function
    | [] -> (List.rev expired, List.rev keep, keep_count)
    | entry :: rest ->
        if is_expired t now entry then split (entry :: expired) keep keep_count rest
        else split expired (entry :: keep) (keep_count + 1) rest
  in
  let expired, keep, keep_count = split [] [] 0 t.idle in
  t.idle <- keep;
  t.idle_count <- keep_count;
  expired

let close_entry t entry =
  Effect.finally
    (Effect.sync (fun () -> mark_closed t))
    (t.release_conn entry.conn)

let rec close_entries t = function
  | [] -> Effect.unit
  | entry :: rest -> Effect.seq (close_entry t entry) (close_entries t rest)

let evict_idle_once t =
  let expired =
    if t.shutting_down || not t.expires_entries then [] else take_expired_idle t
  in
  close_entries t expired

let rec eviction_loop t =
  Effect.delay t.idle_check_interval (evict_idle_once t)
  |> Effect.bind (fun () ->
         if t.shutting_down then Effect.unit else eviction_loop t)

let reserve t =
  if t.shutting_down then Shutdown
  else
    match t.idle with
    | entry :: rest ->
        t.idle <- rest;
        t.idle_count <- t.idle_count - 1;
        t.active <- t.active + 1;
        Use entry
    | [] ->
        if t.total >= t.max_size then
          invalid_arg "Eta_js.Pool invariant violated: no capacity";
        t.total <- t.total + 1;
        t.active <- t.active + 1;
        Open_new

let close_rejected_entry t entry =
  t.health_rejected <- t.health_rejected + 1;
  Effect.finally
    (Effect.sync (fun () -> mark_active_finished t))
    (close_entry t entry)

let release_entry t entry =
  let should_close =
    t.shutting_down
    || t.idle_count >= t.max_idle
    ||
    let now = now_ms () in
    t.expires_entries
    &&
    match t.max_lifetime with
    | Some max_lifetime ->
        duration_expired ~now max_lifetime entry.created_ms
    | None -> false
  in
  if should_close then
    Effect.finally
      (Effect.sync (fun () -> mark_active_finished t))
      (close_entry t entry)
  else
    Effect.sync (fun () ->
        entry.last_used_ms <- now_ms ();
        mark_active_finished t;
        t.idle <- entry :: t.idle;
        t.idle_count <- t.idle_count + 1)

let rec acquire_entry t =
  match reserve t with
  | Shutdown -> Effect.fail `Pool_shutdown
  | Use entry ->
      Effect.catch
        (fun _ ->
          close_rejected_entry t entry |> Effect.bind (fun () -> acquire_entry t))
        (t.health_check entry.conn |> Effect.map (fun () -> entry))
  | Open_new ->
      let opened = ref false in
      Effect.finally
        (Effect.sync (fun () ->
             if not !opened then begin
               mark_active_finished t;
               t.total <- t.total - 1
             end))
        (Effect.bind
           (fun conn ->
             opened := true;
             let entry = make_entry conn in
             t.opened <- t.opened + 1;
             Effect.catch
               (fun _ ->
                 close_rejected_entry t entry
                 |> Effect.bind (fun () -> acquire_entry t))
               (t.health_check conn |> Effect.map (fun () -> entry)))
           t.acquire_conn)

let await_shutdown t =
  if t.shutting_down then Effect.unit
  else
    Effect.Expert.async_leaf (fun _context ~resume ~on_cancel ->
        let waiter : shutdown_waiter =
          {
            active = true;
            resume = (fun () -> resume (Exit.ok ()));
          }
        in
        t.shutdown_waiters <- waiter :: t.shutdown_waiters;
        on_cancel (fun () -> waiter.active <- false))

let with_resource t body =
  if t.shutting_down then Effect.fail `Pool_shutdown
  else
    Effect.bind
      (function
        | None -> Effect.fail `Pool_shutdown
        | Some value -> Effect.pure value)
      (Semaphore.with_permits_or_abort t.sem 1 ~abort:(await_shutdown t)
         (fun () ->
           Effect.acquire_use_release
             ~acquire:(acquire_entry t)
             ~release:(release_entry t)
             (fun entry -> body entry.conn)))

let wait_until_drained t =
  if t.active = 0 then Effect.unit
  else
    Effect.Expert.async_leaf (fun _context ~resume ~on_cancel ->
        let waiter : drain_waiter =
          {
            active = true;
            resume = (fun () -> resume (Exit.ok ()));
          }
        in
        t.drain_waiters <- waiter :: t.drain_waiters;
        on_cancel (fun () -> waiter.active <- false))

let begin_shutdown t =
  let idle =
    if t.shutting_down then []
    else begin
      t.shutting_down <- true;
      wake_shutdown_waiters t;
      let idle = t.idle in
      t.idle <- [];
      t.idle_count <- 0;
      idle
    end
  in
  close_entries t idle

let shutdown ?deadline t =
  let drain = wait_until_drained t in
  let drain =
    match deadline with
    | None -> drain
    | Some deadline ->
        Effect.timeout_as deadline ~on_timeout:`Pool_shutdown_timeout drain
  in
  Effect.seq (begin_shutdown t) drain

let stats t =
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

let create ?(name = "eta.pool") ?kind ~max_size ?max_idle ?idle_lifetime
    ?max_lifetime ?(idle_check_interval = Duration.seconds 1) ~acquire
    ~release ?(health_check = fun _ -> Effect.unit) () =
  let max_idle =
    match max_idle with
    | None -> max_size
    | Some max_idle -> max_idle
  in
  validate ~max_size ~max_idle ~idle_check_interval;
  let t =
    {
      name;
      kind;
      max_size;
      max_idle;
      idle_lifetime;
      max_lifetime;
      expires_entries = Option.is_some idle_lifetime || Option.is_some max_lifetime;
      idle_check_interval;
      acquire_conn = acquire;
      release_conn = release;
      health_check;
      sem = Semaphore.make ~permits:max_size;
      idle = [];
      idle_count = 0;
      total = 0;
      active = 0;
      opened = 0;
      closed = 0;
      health_rejected = 0;
      shutting_down = false;
      drain_waiters = [];
      shutdown_waiters = [];
    }
  in
  let start_daemon =
    if t.expires_entries then Effect.daemon (eviction_loop t) else Effect.unit
  in
  Effect.map (fun () -> t) start_daemon
