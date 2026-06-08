open! Portable

type 'err t = {
  failures : 'err list Atomic.t;
}

let create () =
  { failures = Atomic.make [] }

let append t failure =
  Atomic.update t.failures ~pure_f:(fun failures -> failure :: failures)

let with_parallel f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> Parallel_scheduler.parallel scheduler ~f)

let () =
  let supervisor = create () in
  let counter = ref 0 in
  let failure () = !counter in
  with_parallel (fun parallel ->
    let #((), ()) =
      Parallel.fork_join2
        parallel
        (fun _ -> append supervisor failure)
        (fun _ -> append supervisor failure)
    in
    ())

