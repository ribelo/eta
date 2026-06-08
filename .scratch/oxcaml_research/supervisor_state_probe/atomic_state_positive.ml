open! Portable

type t = {
  failures : int list Atomic.t;
  count : int Atomic.t;
  max_failures : int option;
}

let create ?max_failures () =
  { failures = Atomic.make []; count = Atomic.make 0; max_failures }

let append t failure =
  Atomic.update t.failures ~pure_f:(fun failures -> failure :: failures);
  Atomic.incr t.count

let snapshot t =
  (List.rev (Atomic.get t.failures), Atomic.get t.count, t.max_failures)

let exceeded t =
  match snapshot t with
  | _, count, Some max_failures -> count >= max_failures
  | _, _, None -> false

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
  let failures, count, _ = snapshot supervisor in
  if count <> 500 then failwith "atomic supervisor count mismatch";
  if List.length failures <> 500 then failwith "atomic supervisor lost failures";
  if sum failures <> 125250 then failwith "atomic supervisor corrupted failures";
  if not (exceeded supervisor) then failwith "atomic supervisor threshold mismatch"

