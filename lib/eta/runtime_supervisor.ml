let make ~sw ~max_failures =
  {
    Runtime_supervisor_types.sw;
    max_failures;
    failures = Atomic.make [];
    failure_count = Atomic.make 0;
    next_child_id = Atomic.make 0;
    children = Atomic.make [];
  }

let fork supervisor body =
  Eio.Fiber.fork ~sw:supervisor.Runtime_supervisor_types.sw body

let max_failures supervisor = supervisor.Runtime_supervisor_types.max_failures

let record_failure supervisor failure =
  let rec push () =
    let failures = Atomic.get supervisor.Runtime_supervisor_types.failures in
    if
      not
        (Atomic.compare_and_set supervisor.failures failures
           (failure :: failures))
    then push ()
  in
  push ();
  Atomic.incr supervisor.failure_count

let failures supervisor = Atomic.get supervisor.Runtime_supervisor_types.failures
let failure_count supervisor = Atomic.get supervisor.Runtime_supervisor_types.failure_count

let register_child supervisor cancel =
  let id =
    Atomic.fetch_and_add supervisor.Runtime_supervisor_types.next_child_id 1
  in
  let registration = { Runtime_supervisor_types.id; cancel_child = cancel } in
  let rec push () =
    let children = Atomic.get supervisor.Runtime_supervisor_types.children in
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
    let children = Atomic.get supervisor.Runtime_supervisor_types.children in
    let remaining =
      List.filter
        (fun child -> child.Runtime_supervisor_types.id <> id)
        children
    in
    if not (Atomic.compare_and_set supervisor.children children remaining) then
      remove ()
  in
  remove ()

let cancel_children supervisor =
  List.iter
    (fun child -> child.Runtime_supervisor_types.cancel_child ())
    (Atomic.get supervisor.Runtime_supervisor_types.children)

let make_child ~promise ~cancel = { Runtime_supervisor_types.promise; cancel }
let child_promise child = child.Runtime_supervisor_types.promise
let child_cancel child = child.Runtime_supervisor_types.cancel
