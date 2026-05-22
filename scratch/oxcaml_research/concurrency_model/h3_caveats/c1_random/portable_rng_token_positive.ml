open! Portable

module P_atomic = Portable.Atomic

type random : value mod portable contended = { seed : int P_atomic.t }

type schedule : immutable_data =
  | Spaced of int
  | Jittered of schedule * float * float

let create_random seed = { seed = P_atomic.make seed }

let next_seed seed =
  ((seed * 1_103_515_245) + 12_345) land 0x3fffffff

let next_float random bound =
  let seed = next_seed (P_atomic.get random.seed) in
  P_atomic.set random.seed seed;
  bound *. (float_of_int (seed land 0xffff) /. 65_536.0)

let rec next_delay ~random schedule =
  match schedule with
  | Spaced ms -> ms
  | Jittered (inner, lo, hi) ->
      let base = next_delay ~random inner in
      let factor = lo +. ((hi -. lo) *. next_float random 1.0) in
      int_of_float (float_of_int base *. factor)

let () =
  let random = create_random 17 in
  let schedule = Jittered (Spaced 100, 1.0, 2.0) in
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(a, b) =
            Parallel.fork_join2 parallel
              (fun _ -> next_delay ~random schedule)
              (fun _ -> next_delay ~random schedule)
          in
          if a < 100 || a > 199 || b < 100 || b > 199 then
            failwith "jitter outside bounds";
          Printf.printf "portable_rng_token_positive a=%d b=%d\n%!" a b))
