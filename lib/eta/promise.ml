type ('a, 'err) waiter = {
  contract : Runtime_contract.t;
  resolver : ('a, 'err) Exit.t Runtime_contract.resolver;
}

type ('a, 'err) state =
  | Pending of ('a, 'err) waiter list
  | Settled of ('a, 'err) Exit.t

type ('a, 'err) t = {
  lock : Sync_lock.t;
  mutable state : ('a, 'err) state;
}

let create () = { lock = Sync_lock.create (); state = Pending [] }
let with_lock t f = Sync_lock.use t.lock f

let remove_waiter t waiter =
  with_lock t @@ fun () ->
  match t.state with
  | Settled exit -> `Settled exit
  | Pending waiters ->
      t.state <- Pending (List.filter (fun candidate -> candidate != waiter) waiters);
      `Removed

let await t =
  Effect_erasure.public_runtime ~leaf_name:"Promise.await"
    ~footprint:Effect_core.concurrency_footprint t
  @@ fun contract t ->
  let backend_promise, resolver = contract.Runtime_contract.create_promise () in
  let waiter = { contract; resolver } in
  match
    with_lock t @@ fun () ->
    match t.state with
    | Settled exit -> `Settled exit
    | Pending waiters ->
        t.state <- Pending (waiter :: waiters);
        `Await
  with
  | `Settled exit -> exit
  | `Await -> (
      try contract.Runtime_contract.await_promise backend_promise with exn ->
        match contract.Runtime_contract.cancellation_reason exn with
        | Some _ -> (
            match remove_waiter t waiter with
            | `Settled exit -> exit
            | `Removed -> raise exn)
        | None ->
            ignore (remove_waiter t waiter : [ `Removed | `Settled of _ ]);
            raise exn)

let resolve t exit =
  Effect_erasure.public_runtime ~leaf_name:"Promise.resolve"
    ~footprint:Effect_core.concurrency_footprint t
  @@ fun _contract t ->
  match
    with_lock t @@ fun () ->
    match t.state with
    | Settled _ -> None
    | Pending waiters ->
        t.state <- Settled exit;
        Some (List.rev waiters)
  with
  | None -> Exit.Ok false
  | Some waiters ->
      List.iter
        (fun waiter ->
          waiter.contract.Runtime_contract.resolve_promise waiter.resolver exit)
        waiters;
      Exit.Ok true
