module Effect = Eta.Effect
module Exit = Eta.Exit
module Cause = Eta.Cause
module Duration = Eta.Duration
module Runtime_contract = Eta.Runtime_contract
module Sync_lock = Eta.Sync_lock

module type Key = Hashtbl.HashedType

module Make (Key : Key) = struct
  module Table = Hashtbl.Make (Key)

  type key = Key.t

  type stats = {
    hits : int;
    misses : int;
    loads : int;
    load_failures : int;
    evictions : int;
    expirations : int;
    current_size : int;
  }

  type ('value, 'err) pending = {
    promise : ('value, 'err) Exit.t Runtime_contract.promise;
    resolver : ('value, 'err) Exit.t Runtime_contract.resolver;
    mutable resolved : bool;
  }

  type ('value, 'err) state =
    | Pending of ('value, 'err) pending
    | Complete of {
        exit : ('value, 'err) Exit.t;
        loaded_at_ms : int;
        ttl_ms : int;
      }

  type ('value, 'err) entry = {
    key : key;
    mutable state : ('value, 'err) state;
    mutable prev : ('value, 'err) entry option;
    mutable next : ('value, 'err) entry option;
  }

  type ('value, 'err) t = {
    capacity : int;
    lookup : key -> ('value, 'err) Effect.t;
    time_to_live : ('value, 'err) Exit.t -> key -> Duration.t;
    contract : Runtime_contract.t;
    lock : Sync_lock.t;
    table : ('value, 'err) entry Table.t;
    mutable head : ('value, 'err) entry option;
    mutable tail : ('value, 'err) entry option;
    mutable current_size : int;
    mutable hits : int;
    mutable misses : int;
    mutable loads : int;
    mutable load_failures : int;
    mutable evictions : int;
    mutable expirations : int;
  }

  let now_ms t = t.contract.Runtime_contract.now_ms ()

  let invalid_state message =
    invalid_arg ("Eta_cache invariant violated: " ^ message)

  let is_head t entry =
    match t.head with
    | Some head -> head == entry
    | None -> false

  let is_linked t entry =
    is_head t entry || Option.is_some entry.prev || Option.is_some entry.next

  let detach_lru t entry =
    match is_linked t entry with
    | false -> invalid_state "detaching unlinked entry"
    | true ->
        (match entry.prev with
         | None -> t.head <- entry.next
         | Some prev -> prev.next <- entry.next);
        (match entry.next with
         | None -> t.tail <- entry.prev
         | Some next -> next.prev <- entry.prev);
        entry.prev <- None;
        entry.next <- None

  let link_front t entry =
    if is_linked t entry then invalid_state "linking linked entry";
    entry.prev <- None;
    entry.next <- t.head;
    (match t.head with
     | None -> t.tail <- Some entry
     | Some old_head -> old_head.prev <- Some entry);
    t.head <- Some entry

  let move_to_front t entry =
    if not (is_head t entry) then (
      detach_lru t entry;
      link_front t entry)

  let table_points_to t entry =
    match Table.find_opt t.table entry.key with
    | Some current -> current == entry
    | None -> false

  let remove_complete_lru_locked t entry =
    detach_lru t entry;
    if t.current_size <= 0 then invalid_state "current_size underflow";
    t.current_size <- t.current_size - 1

  let remove_entry_locked t entry =
    (match entry.state with
     | Pending _ -> ()
     | Complete _ -> remove_complete_lru_locked t entry);
    if table_points_to t entry then Table.remove t.table entry.key

  let remove_key_locked t key =
    match Table.find_opt t.table key with
    | None -> ()
    | Some entry -> remove_entry_locked t entry

  let evict_tail_locked t =
    match t.tail with
    | None -> invalid_state "missing LRU tail"
    | Some entry ->
        remove_entry_locked t entry;
        t.evictions <- t.evictions + 1

  let rec enforce_capacity_locked t =
    if t.current_size > t.capacity then (
      evict_tail_locked t;
      enforce_capacity_locked t)

  let expired t ~loaded_at_ms ~ttl_ms =
    let elapsed = now_ms t - loaded_at_ms in
    elapsed < 0 || elapsed >= ttl_ms

  let expire_entry_locked t entry =
    remove_entry_locked t entry;
    t.expirations <- t.expirations + 1

  let rec finalizer_contains_interrupt = function
    | Cause.Finalizer.Interrupt _ -> true
    | Fail _ | Die _ -> false
    | Sequential causes | Concurrent causes ->
        List.exists finalizer_contains_interrupt causes
    | Finalizer cause -> finalizer_contains_interrupt cause
    | Suppressed { primary; finalizer } ->
        finalizer_contains_interrupt primary || finalizer_contains_interrupt finalizer

  let rec contains_interrupt = function
    | Cause.Interrupt _ -> true
    | Fail _ | Die _ -> false
    | Sequential causes | Concurrent causes -> List.exists contains_interrupt causes
    | Finalizer cause -> finalizer_contains_interrupt cause
    | Suppressed { primary; finalizer } ->
        contains_interrupt primary || finalizer_contains_interrupt finalizer

  let cacheable_exit = function
    | Exit.Ok _ -> true
    | Exit.Error cause ->
        (not (contains_interrupt cause))
        && Cause.defects cause = [] && Cause.failures cause <> []

  let retention t duration =
    let ttl_ms = Duration.to_ms duration in
    if ttl_ms = 0 then None
    else Some (now_ms t, ttl_ms)

  let expiry_for_exit t key exit =
    if cacheable_exit exit then
      Effect.sync (fun () -> retention t (t.time_to_live exit key))
      |> Effect.exit
    else Effect.pure (Exit.Ok None)

  let replay exit = Effect.Expert.make ~leaf_name:"eta_cache.replay" (fun _ -> exit)

  let await_pending t pending =
    Effect.Expert.make ~leaf_name:"eta_cache.await" @@ fun _ ->
    t.contract.Runtime_contract.await_promise pending.promise

  let resolve_pending t pending exit =
    Effect.sync @@ fun () ->
    if not pending.resolved then (
      pending.resolved <- true;
      t.contract.Runtime_contract.resolve_promise pending.resolver exit)

  let make_pending t =
    let promise, resolver = t.contract.Runtime_contract.create_promise () in
    { promise; resolver; resolved = false }

  let new_pending_entry_locked t key =
    let pending = make_pending t in
    let entry = { key; state = Pending pending; prev = None; next = None } in
    Table.replace t.table key entry;
    (entry, pending)

  let start_load_locked t key =
    t.misses <- t.misses + 1;
    t.loads <- t.loads + 1;
    let entry, pending = new_pending_entry_locked t key in
    `Load (entry, pending)

  let record_lookup_exit_locked t = function
    | Exit.Ok _ -> ()
    | Exit.Error _ -> t.load_failures <- t.load_failures + 1

  let complete_entry_locked t entry exit (loaded_at_ms, ttl_ms) =
    entry.state <- Complete { exit; loaded_at_ms; ttl_ms };
    link_front t entry;
    t.current_size <- t.current_size + 1;
    enforce_capacity_locked t

  let finish_pending t entry pending lookup_exit expiry_exit =
    let final_exit, expiry =
      match expiry_exit with
      | Exit.Ok expiry -> (lookup_exit, expiry)
      | Exit.Error cause -> (Exit.Error cause, None)
    in
    Effect.sync
      (fun () ->
        Sync_lock.use t.lock @@ fun () ->
        record_lookup_exit_locked t lookup_exit;
        if table_points_to t entry then
          match entry.state with
          | Pending current when current == pending -> (
              match expiry with
              | Some retention ->
                  complete_entry_locked t entry final_exit retention
              | None -> Table.remove t.table entry.key)
          | Pending _ | Complete _ -> ())
    |> Effect.bind (fun () -> resolve_pending t pending final_exit)
    |> Effect.bind (fun () -> replay final_exit)

  let call_lookup t key =
    Effect.sync (fun () -> t.lookup key) |> Effect.bind Fun.id

  let run_pending_lookup t entry pending =
    call_lookup t entry.key
    |> Effect.exit
    |> Effect.bind (fun lookup_exit ->
           expiry_for_exit t entry.key lookup_exit
           |> Effect.bind (fun expiry_exit ->
                  finish_pending t entry pending lookup_exit expiry_exit))

  let get_decision_locked t key =
    match Table.find_opt t.table key with
    | Some ({ state = Complete { exit; loaded_at_ms; ttl_ms }; _ } as entry) ->
        if expired t ~loaded_at_ms ~ttl_ms then (
          expire_entry_locked t entry;
          start_load_locked t key)
        else (
          t.hits <- t.hits + 1;
          move_to_front t entry;
          `Hit exit)
    | Some { state = Pending pending; _ } -> `Await pending
    | None -> start_load_locked t key

  let get t key =
    Effect.sync (fun () -> Sync_lock.use t.lock @@ fun () -> get_decision_locked t key)
    |> Effect.bind (function
         | `Hit exit -> replay exit
         | `Await pending -> await_pending t pending
         | `Load (entry, pending) -> run_pending_lookup t entry pending)

  let get_if_present t key =
    Effect.sync @@ fun () ->
    Sync_lock.use t.lock @@ fun () ->
    match Table.find_opt t.table key with
    | Some ({ state = Complete { exit; loaded_at_ms; ttl_ms }; _ } as entry) ->
        if expired t ~loaded_at_ms ~ttl_ms then (
          expire_entry_locked t entry;
          None)
        else (
          move_to_front t entry;
          Some exit)
    | Some { state = Pending _; _ } | None -> None

  let store_refreshed_locked t key exit (loaded_at_ms, ttl_ms) =
    remove_key_locked t key;
    let entry =
      {
        key;
        state = Complete { exit; loaded_at_ms; ttl_ms };
        prev = None;
        next = None;
      }
    in
    Table.replace t.table key entry;
    link_front t entry;
    t.current_size <- t.current_size + 1;
    enforce_capacity_locked t

  let finish_refresh t key lookup_exit expiry_exit =
    let final_exit, expiry =
      match expiry_exit with
      | Exit.Ok expiry -> (lookup_exit, expiry)
      | Exit.Error cause -> (Exit.Error cause, None)
    in
    Effect.sync
      (fun () ->
        Sync_lock.use t.lock @@ fun () ->
        record_lookup_exit_locked t lookup_exit;
        match expiry with
        | Some retention -> store_refreshed_locked t key final_exit retention
        | None ->
            if cacheable_exit lookup_exit then remove_key_locked t key)
    |> Effect.bind (fun () -> replay final_exit)

  let refresh t key =
    Effect.sync (fun () ->
        Sync_lock.use t.lock @@ fun () -> t.loads <- t.loads + 1)
    |> Effect.bind (fun () ->
           call_lookup t key
           |> Effect.exit
           |> Effect.bind (fun lookup_exit ->
                  expiry_for_exit t key lookup_exit
                  |> Effect.bind (fun expiry_exit ->
                         finish_refresh t key lookup_exit expiry_exit)))

  let invalidate t key =
    Effect.sync (fun () -> Sync_lock.use t.lock @@ fun () -> remove_key_locked t key)

  let invalidate_all t =
    Effect.sync @@ fun () ->
    Sync_lock.use t.lock @@ fun () ->
    Table.clear t.table;
    t.head <- None;
    t.tail <- None;
    t.current_size <- 0

  let size t =
    Effect.sync (fun () -> Sync_lock.use t.lock @@ fun () -> t.current_size)

  let stats_locked t =
    {
      hits = t.hits;
      misses = t.misses;
      loads = t.loads;
      load_failures = t.load_failures;
      evictions = t.evictions;
      expirations = t.expirations;
      current_size = t.current_size;
    }

  let stats t =
    Effect.sync (fun () -> Sync_lock.use t.lock @@ fun () -> stats_locked t)

  let make ~capacity ~lookup ~time_to_live =
    if capacity <= 0 then
      invalid_arg "Eta_cache.Make.make: capacity must be > 0";
    Effect.Expert.make ~leaf_name:"eta_cache.make" @@ fun context ->
    let contract = Effect.Expert.contract context in
    Exit.Ok
      {
        capacity;
        lookup;
        time_to_live;
        contract;
        lock = Sync_lock.create ();
        table = Table.create capacity;
        head = None;
        tail = None;
        current_size = 0;
        hits = 0;
        misses = 0;
        loads = 0;
        load_failures = 0;
        evictions = 0;
        expirations = 0;
      }
end
