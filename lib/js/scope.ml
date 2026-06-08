type close_waiter = {
  scheduler : Scheduler.t;
  resume : unit -> unit;
}

type child = {
  id : int;
  cancel : Obj.t Cause.t -> unit;
  mutable done_ : bool;
}

type t = {
  mutable closed : bool;
  mutable children : child list;
  mutable close_waiters : close_waiter list;
}

let create () = { closed = false; children = []; close_waiters = [] }
let is_closed t = t.closed
let child_count t = List.length t.children

let register_child t ~id ~cancel =
  if t.closed then invalid_arg "Eta_js.Scope.register_child: scope is closed";
  let child = { id; cancel; done_ = false } in
  t.children <- child :: t.children;
  child

let wake_close_waiters t =
  match t.close_waiters with
  | [] -> ()
  | waiters ->
      t.close_waiters <- [];
      List.iter
        (fun waiter -> Scheduler.enqueue waiter.scheduler waiter.resume)
        waiters

let child_done t child =
  if not child.done_ then begin
    child.done_ <- true;
    t.children <- List.filter (fun current -> current != child) t.children;
    if t.closed && t.children = [] then wake_close_waiters t
  end

let close t ~scheduler ?(cause = Cause.interrupt) resume =
  if t.children = [] then Scheduler.enqueue scheduler resume
  else begin
    let first_close = not t.closed in
    t.closed <- true;
    t.close_waiters <- { scheduler; resume } :: t.close_waiters;
    if first_close then
      List.iter
        (fun child -> if not child.done_ then child.cancel cause)
        t.children
  end
