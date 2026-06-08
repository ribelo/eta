open! Portable

type item : immutable_data = { seq : int }

type inbox = {
  items : item list Atomic.t;
  count : int Atomic.t;
  capacity : int;
}

let create ~capacity = { items = Atomic.make []; count = Atomic.make 0; capacity }

let push t item =
  Atomic.incr t.count;
  Atomic.update t.items ~pure_f:(fun items -> item :: items)

let () =
  let inbox = create ~capacity:4 in
  push inbox { seq = 0 };
  Atomic.set inbox.count 0;
  push inbox { seq = 1 };
  let drained = Atomic.exchange inbox.items [] in
  let count_after_interleaving = Atomic.get inbox.count in
  if List.length drained <> 2 || count_after_interleaving <> 1 then
    failwith "negative fixture did not expose count/items mismatch";
  Printf.printf
    "detected_mixed_push_drain_mismatch drained=%d stale_count=%d\n%!"
    (List.length drained) count_after_interleaving

