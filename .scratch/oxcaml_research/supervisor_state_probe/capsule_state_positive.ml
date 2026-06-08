open! Portable

module C = Capsule.Expert
module Mutex = Capsule.Blocking_sync.Mutex

type state = {
  mutable failures : int list;
  mutable count : int;
  max_failures : int option;
}

type t = P : {
  data : (state, 'k) C.Data.t;
  mutex : 'k Mutex.t;
} -> t

let create ?max_failures () =
  let C.Key.P key = C.create () in
  let data = C.Data.create (fun () -> { failures = []; count = 0; max_failures }) in
  let mutex = Mutex.create key in
  P { data; mutex }

let append (P { data; mutex }) failure =
  Mutex.with_lock mutex ~f:(fun password ->
    C.Data.iter data ~password ~f:(fun state ->
      state.failures <- failure :: state.failures;
      state.count <- state.count + 1))

let metrics (P { data; mutex }) =
  Mutex.with_lock mutex ~f:(fun password ->
    C.Data.extract data ~password ~f:(fun state ->
      let sum = List.fold_left ( + ) 0 state.failures in
      let exceeded =
        match state.max_failures with
        | None -> false
        | Some max_failures -> state.count >= max_failures
      in
      (state.count, sum, exceeded)))

let exceeded t =
  match metrics t with
  | _, _, exceeded -> exceeded

let with_parallel f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> Parallel_scheduler.parallel scheduler ~f)

let append_range supervisor first last =
  for failure = first to last do
    append supervisor failure
  done

let sum values =
  List.fold_left ( + ) 0 values

let () =
  let supervisor = create ~max_failures:300 () in
  with_parallel (fun parallel ->
    let #((), ()) =
      Parallel.fork_join2
        parallel
        (fun _ -> append_range supervisor 1 250)
        (fun _ -> append_range supervisor 251 500)
    in
    ());
  let count, failure_sum, _ = metrics supervisor in
  if count <> 500 then failwith "capsule supervisor count mismatch";
  if failure_sum <> 125250 then failwith "capsule supervisor corrupted failures";
  if not (exceeded supervisor) then failwith "capsule supervisor threshold mismatch"
