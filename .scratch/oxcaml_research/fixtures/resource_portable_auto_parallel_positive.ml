open! Portable

type ('err, 'a) resource = {
  value : 'a option Atomic.t;
  failures : 'err list Atomic.t;
}

let make () =
  { value = Atomic.make None; failures = Atomic.make [] }

let make_portable_refresh resource =
  let (refresh @ portable) result =
    match result with
    | Ok value -> Atomic.set resource.value (Some value)
    | Error err ->
        Atomic.update resource.failures ~pure_f:(fun failures -> err :: failures)
  in
  refresh

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let smoke () =
  let resource = make () in
  let refresh = make_portable_refresh resource in
  with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #((), ()) =
            Parallel.fork_join2
              parallel
              (fun _ -> refresh (Ok 42))
              (fun _ -> refresh (Error "refresh failed"))
          in
          ()));
  match Atomic.get resource.value, Atomic.get resource.failures with
  | Some 42, [ "refresh failed" ] -> ()
  | _ -> failwith "portable Resource.auto-shaped state did not survive parallel refresh"

let () = smoke ()
