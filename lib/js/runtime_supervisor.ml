type child_registration = {
  id : int;
  cancel_child : unit -> unit;
  settled : unit Runtime_promise.t;
}

type ('s, !'err) supervisor = {
  max_failures : int option;
  mutable failures : 'err Cause.t list;
  mutable failure_count : int;
  mutable next_child_id : int;
  mutable children : child_registration list;
}

type ('s, !'err, !'a) child = {
  promise : ('a, 'err Cause.t) result Runtime_promise.t;
  cancel : unit -> unit;
}

let make ~max_failures =
  {
    max_failures;
    failures = [];
    failure_count = 0;
    next_child_id = 0;
    children = [];
  }

let max_failures supervisor = supervisor.max_failures

let record_failure supervisor failure =
  supervisor.failures <- failure :: supervisor.failures;
  supervisor.failure_count <- supervisor.failure_count + 1

let failures supervisor = supervisor.failures
let failure_count supervisor = supervisor.failure_count

let register_child supervisor ~cancel ~settled =
  let id = supervisor.next_child_id in
  supervisor.next_child_id <- supervisor.next_child_id + 1;
  supervisor.children <- { id; cancel_child = cancel; settled } :: supervisor.children;
  id

let unregister_child supervisor id =
  supervisor.children <-
    List.filter (fun child -> child.id <> id) supervisor.children

let live_children supervisor = supervisor.children
let cancel_registration child = child.cancel_child ()
let registration_settled child = child.settled

let make_child ~promise ~cancel = { promise; cancel }
let child_promise child = child.promise
let child_cancel child = child.cancel
