type priority = int

type task = {
  priority : priority;
  seq : int;
  run : unit -> unit;
}

type t = {
  max_ops_before_yield : int;
  mutable next_seq : int;
  mutable scheduled : bool;
  mutable ready : task list;
}

let create ?(max_ops_before_yield = 2_048) () =
  if max_ops_before_yield <= 0 then
    invalid_arg "Eta_js.Scheduler.create: max_ops_before_yield must be > 0";
  { max_ops_before_yield; next_seq = 0; scheduled = false; ready = [] }

let task_before left right =
  left.priority < right.priority
  || (left.priority = right.priority && left.seq < right.seq)

let insert_task task ready =
  let rec loop prefix = function
    | [] -> List.rev_append prefix [ task ]
    | current :: rest as suffix ->
        if task_before task current then List.rev_append prefix (task :: suffix)
        else loop (current :: prefix) rest
  in
  loop [] ready

let pop_ready t =
  match t.ready with
  | [] -> None
  | task :: rest ->
      t.ready <- rest;
      Some task

let rec drain_ready t =
  t.scheduled <- false;
  match pop_ready t with
  | None -> ()
  | Some task ->
      task.run ();
      drain_ready t

let schedule_drain t =
  if not t.scheduled then begin
    t.scheduled <- true;
    Js_interop.queue_microtask (fun () -> drain_ready t)
  end

let enqueue t ?(priority = 0) run =
  let task = { priority; seq = t.next_seq; run } in
  t.next_seq <- t.next_seq + 1;
  t.ready <- insert_task task t.ready;
  schedule_drain t

let ready_count t = List.length t.ready

let should_yield t ~op_count = op_count >= t.max_ops_before_yield
