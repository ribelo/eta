let make ~sw ~max_failures =
  {
    Runtime_supervisor_types.sw;
    max_failures;
    failures = Atomic.make [];
    failure_count = Atomic.make 0;
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
  let rec push () =
    let children = Atomic.get supervisor.Runtime_supervisor_types.children in
    if
      not
        (Atomic.compare_and_set supervisor.children children (cancel :: children))
    then push ()
  in
  push ()

let cancel_children supervisor =
  List.iter
    (fun cancel -> cancel ())
    (Atomic.get supervisor.Runtime_supervisor_types.children)

let make_child ~promise ~cancel = { Runtime_supervisor_types.promise; cancel }
let child_promise child = child.Runtime_supervisor_types.promise
let child_cancel child = child.Runtime_supervisor_types.cancel
