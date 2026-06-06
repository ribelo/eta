module P_atomic = Atomic

module P_atomic_array = struct
  type 'a t = 'a Atomic.t array

  let create ~len value = Array.init len (fun _ -> Atomic.make value)
  let get slots index = Atomic.get slots.(index)
  let set slots index value = Atomic.set slots.(index) value
end

type state = {
  head : int;
  tail : int;
  published : int;
  closed : bool;
}

type ('a) t = {
  capacity : int;
  state : state P_atomic.t;
  slots : 'a option P_atomic_array.t;
}

type push_result =
  | Pushed
  | Full
  | Closed

type 'a take_result =
  | Value of 'a
  | Empty
  | Closed_empty

let create ~capacity =
  if capacity <= 0 then invalid_arg "Portable_queue.create: capacity must be > 0";
  {
    capacity;
    state = P_atomic.make { head = 0; tail = 0; published = 0; closed = false };
    slots = P_atomic_array.create ~len:capacity None;
  }

let cas_state queue seen replace_with =
  P_atomic.compare_and_set queue.state seen replace_with

let rec wait_empty slots index =
  match P_atomic_array.get slots index with
  | None -> ()
  | Some _ ->
      Domain.cpu_relax ();
      wait_empty slots index

let rec try_push queue value =
  let state = P_atomic.get queue.state in
  if state.closed then Closed
  else if state.tail - state.head >= queue.capacity then Full
  else
    let ticket = state.tail in
    let next = { state with tail = state.tail + 1 } in
    if cas_state queue state next then (
      let index = ticket mod queue.capacity in
      wait_empty queue.slots index;
      P_atomic_array.set queue.slots index (Some value);
      let rec publish () =
        let state = P_atomic.get queue.state in
        if state.published = ticket then
          let next = { state with published = ticket + 1 } in
          if not (cas_state queue state next) then publish ()
        else (
          Domain.cpu_relax ();
          publish ())
      in
      publish ();
      Pushed)
    else try_push queue value

let rec try_take queue =
  let state = P_atomic.get queue.state in
  if state.head = state.published then
    if state.closed && state.head = state.tail then Closed_empty
    else if state.head = state.tail then Empty
    else (
      Domain.cpu_relax ();
      try_take queue)
  else
    let index = state.head mod queue.capacity in
    match P_atomic_array.get queue.slots index with
    | None ->
        Domain.cpu_relax ();
        try_take queue
    | Some value ->
        let next = { state with head = state.head + 1 } in
        if cas_state queue state next then (
          P_atomic_array.set queue.slots index None;
          Value value)
        else try_take queue

let rec close queue =
  let state = P_atomic.get queue.state in
  if state.closed then ()
  else if cas_state queue state { state with closed = true } then ()
  else close queue
