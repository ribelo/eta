open! Portable

type bad_event = {
  task_id : int;
  encode : int -> int;
}

let event = { task_id = 1; encode = (fun x -> x + 1) }

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let () =
  ignore
    (with_scheduler (fun scheduler ->
       Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
         Parallel.fork_join2 parallel (fun _ -> event) (fun _ -> event))))

