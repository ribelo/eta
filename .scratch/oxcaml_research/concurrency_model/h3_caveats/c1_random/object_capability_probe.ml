open! Portable

module P_atomic = Portable.Atomic

class type random = object
  method float : float -> float
end

type schedule : immutable_data =
  | Spaced of int
  | Jittered of schedule * float * float

let next_seed seed =
  ((seed * 1_103_515_245) + 12_345) land 0x3fffffff

let make_random seed : random =
  let state = P_atomic.make seed in
  object
    method float bound =
      let seed = next_seed (P_atomic.get state) in
      P_atomic.set state seed;
      bound *. (float_of_int (seed land 0xffff) /. 65_536.0)
  end

let rec next_delay ~random schedule =
  match schedule with
  | Spaced ms -> ms
  | Jittered (inner, lo, hi) ->
      let base = next_delay ~random inner in
      let factor = lo +. ((hi -. lo) *. random#float 1.0) in
      int_of_float (float_of_int base *. factor)

let () =
  let random = make_random 17 in
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
          Printf.printf "object_capability_probe a=%d b=%d\n%!" a b))
