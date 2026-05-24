let make ~sw ~max_failures =
  {
    Effect_ast.sw;
    max_failures;
    failures = Atomic.make [];
    failure_count = Atomic.make 0;
    children = Atomic.make [];
  }

let fork supervisor body = Eio.Fiber.fork ~sw:supervisor.Effect_ast.sw body
let max_failures supervisor = supervisor.Effect_ast.max_failures

let record_failure supervisor failure =
  let rec push () =
    let failures = Atomic.get supervisor.Effect_ast.failures in
    if
      not
        (Atomic.compare_and_set supervisor.failures failures
           (failure :: failures))
    then push ()
  in
  push ();
  Atomic.incr supervisor.failure_count

let failures supervisor = Atomic.get supervisor.Effect_ast.failures
let failure_count supervisor = Atomic.get supervisor.Effect_ast.failure_count

let register_child supervisor cancel =
  let rec push () =
    let children = Atomic.get supervisor.Effect_ast.children in
    if
      not
        (Atomic.compare_and_set supervisor.children children (cancel :: children))
    then push ()
  in
  push ()

let cancel_children supervisor =
  List.iter (fun cancel -> cancel ()) (Atomic.get supervisor.Effect_ast.children)

let make_child ~promise ~cancel = { Effect_ast.promise; cancel }
let child_promise child = child.Effect_ast.promise
let child_cancel child = child.Effect_ast.cancel
