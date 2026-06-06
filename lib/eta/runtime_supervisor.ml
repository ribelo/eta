type child_registration = {
  id : int;
  cancel_child : unit -> unit;
}

type ('s, !'err) supervisor = {
  scope : Runtime_contract.scope;
  max_failures : int option;
  failures : 'err Cause.t list Atomic.t;
  failure_count : int Atomic.t;
  next_child_id : int Atomic.t;
  (* Live child cancellation hooks only; child fibers unregister on settlement
     so long-lived supervisor scopes do not retain completed children. *)
  children : child_registration list Atomic.t;
}

type ('s, !'err, !'a) child = {
  promise : ('a, 'err Cause.t) result Runtime_contract.promise;
  cancel : unit -> unit;
}

let make ~sw ~max_failures =
  {
    scope = sw;
    max_failures;
    failures = Atomic.make [];
    failure_count = Atomic.make 0;
    next_child_id = Atomic.make 0;
    children = Atomic.make [];
  }

let scope supervisor = supervisor.scope
let max_failures supervisor = supervisor.max_failures

let record_failure supervisor failure =
  let rec push () =
    let failures = Atomic.get supervisor.failures in
    if
      not
        (Atomic.compare_and_set supervisor.failures failures
           (failure :: failures))
    then push ()
  in
  push ();
  Atomic.incr supervisor.failure_count

let failures supervisor = Atomic.get supervisor.failures
let failure_count supervisor = Atomic.get supervisor.failure_count

let register_child supervisor cancel =
  let id = Atomic.fetch_and_add supervisor.next_child_id 1 in
  let registration = { id; cancel_child = cancel } in
  let rec push () =
    let children = Atomic.get supervisor.children in
    if
      not
        (Atomic.compare_and_set supervisor.children children
           (registration :: children))
    then push ()
  in
  push ();
  id

let unregister_child supervisor id =
  let rec remove () =
    let children = Atomic.get supervisor.children in
    let remaining = List.filter (fun child -> child.id <> id) children in
    if not (Atomic.compare_and_set supervisor.children children remaining) then
      remove ()
  in
  remove ()

let cancel_children supervisor =
  List.iter (fun child -> child.cancel_child ()) (Atomic.get supervisor.children)

let make_child ~promise ~cancel = { promise; cancel }
let child_promise child = child.promise
let child_cancel child = child.cancel
