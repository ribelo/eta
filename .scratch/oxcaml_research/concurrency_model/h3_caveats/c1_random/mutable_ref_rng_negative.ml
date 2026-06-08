open! Portable

let seed = ref 1

let next_seed value =
  ((value * 1_103_515_245) + 12_345) land 0x3fffffff

let (jitter @ portable) base =
  seed := next_seed !seed;
  let factor = 1.0 +. (float_of_int (!seed land 0xffff) /. 65_536.0) in
  int_of_float (float_of_int base *. factor)

let () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(a, b) =
            Parallel.fork_join2 parallel
              (fun _ -> jitter 100)
              (fun _ -> jitter 100)
          in
          ignore (a, b)))
