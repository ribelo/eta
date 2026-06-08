open! Portable

type 'a sink = {
  values : 'a list Atomic.t;
}

let make_sink () =
  { values = Atomic.make [] }

let make_emit sink =
  let (emit @ portable) value =
    Atomic.update sink.values ~pure_f:(fun values -> value :: values)
  in
  emit

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let smoke () =
  let sink = make_sink () in
  let emit = make_emit sink in
  with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #((), ()) =
            Parallel.fork_join2
              parallel
              (fun _ -> emit 1)
              (fun _ -> emit 2)
          in
          ()));
  match List.sort compare (Atomic.get sink.values) with
  | [ 1; 2 ] -> ()
  | _ -> failwith "portable stream sink lost a parallel emit"

let () = smoke ()
