type fiber_status =
  | Ready
  | Running
  | Waiting
  | Done

type packed_exit = Exit : ('a, 'err) Exit.t -> packed_exit

type t = {
  id : int;
  scheduler : Scheduler.t;
  scope : Scope.t;
  parent : t option;
  mutable status : fiber_status;
  mutable op_count : int;
  mutable interruptible : bool;
  mutable cancel_cause : Obj.t Cause.t option;
  mutable exit : packed_exit option;
  mutable observers : (packed_exit -> unit) list;
  mutable children : t list;
  locals : Runtime_local.table;
  mutable cancel_waiter : (unit -> unit) option;
  mutable scope_child : Scope.child option;
}

let next_id = ref 0

let fresh_id () =
  let id = !next_id in
  incr next_id;
  id

let create_root ~scheduler =
  {
    id = fresh_id ();
    scheduler;
    scope = Scope.create ();
    parent = None;
    status = Ready;
    op_count = 0;
    interruptible = true;
    cancel_cause = None;
    exit = None;
    observers = [];
    children = [];
    locals = Runtime_local.create_table ();
    cancel_waiter = None;
    scope_child = None;
  }

let cancel fiber cause =
  if fiber.status <> Done then begin
    fiber.cancel_cause <- Some cause;
    match fiber.cancel_waiter with
    | None -> ()
    | Some resume -> Scheduler.enqueue fiber.scheduler resume
  end

let create_child parent =
  let id = fresh_id () in
  let child_ref = ref None in
  let scope_child =
    Scope.register_child parent.scope ~id ~cancel:(fun cause ->
        match !child_ref with
        | None -> ()
        | Some child -> cancel child cause)
  in
  let child =
    {
      id;
      scheduler = parent.scheduler;
      scope = parent.scope;
      parent = Some parent;
      status = Ready;
      op_count = 0;
      interruptible = true;
      cancel_cause = None;
      exit = None;
      observers = [];
      children = [];
      locals = Runtime_local.copy_table parent.locals;
      cancel_waiter = None;
      scope_child = Some scope_child;
    }
  in
  child_ref := Some child;
  parent.children <- child :: parent.children;
  child

let id fiber = fiber.id
let scheduler fiber = fiber.scheduler
let scope fiber = fiber.scope
let status fiber = fiber.status
let set_status fiber status = fiber.status <- status
let child_count fiber = List.length fiber.children
let cancel_cause fiber = fiber.cancel_cause
let exit fiber = fiber.exit

let observe fiber observer =
  match fiber.exit with
  | Some exit -> Scheduler.enqueue fiber.scheduler (fun () -> observer exit)
  | None -> fiber.observers <- observer :: fiber.observers

let remove_from_parent fiber =
  match fiber.parent with
  | None -> ()
  | Some parent ->
      parent.children <- List.filter (fun child -> child != fiber) parent.children

let finish fiber exit =
  if fiber.status = Done then invalid_arg "Eta_js.Runtime_fiber.finish: already done";
  fiber.status <- Done;
  fiber.exit <- Some exit;
  remove_from_parent fiber;
  (match fiber.scope_child with
  | None -> ()
  | Some child ->
      fiber.scope_child <- None;
      Scope.child_done fiber.scope child);
  let observers = List.rev fiber.observers in
  fiber.observers <- [];
  List.iter
    (fun observer -> Scheduler.enqueue fiber.scheduler (fun () -> observer exit))
    observers

let interruptible fiber = fiber.interruptible
let set_interruptible fiber value = fiber.interruptible <- value
let set_cancel_waiter fiber waiter = fiber.cancel_waiter <- waiter
let local_get fiber key = Runtime_local.get fiber.locals key
let local_set fiber key value = Runtime_local.set fiber.locals key value
let local_with_binding fiber key value f =
  Runtime_local.with_binding fiber.locals key value f
