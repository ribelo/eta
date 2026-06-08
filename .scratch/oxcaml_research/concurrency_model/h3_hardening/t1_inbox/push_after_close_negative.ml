open! Portable

type item : immutable_data = { seq : int }

type old_inbox = {
  items : item list Atomic.t;
  count : int Atomic.t;
  capacity : int;
}

let create ~capacity = { items = Atomic.make []; count = Atomic.make 0; capacity }

let old_push_bounded t item =
  if Atomic.get t.count >= t.capacity
  then false
  else (
    Atomic.incr t.count;
    Atomic.update t.items ~pure_f:(fun items -> item :: items);
    true)

let () =
  let inbox = create ~capacity:2 in
  if not (old_push_bounded inbox { seq = 0 }) then failwith "initial push failed";
  let drained_before_late_push = Atomic.exchange inbox.items [] in
  Atomic.set inbox.count 0;
  if not (old_push_bounded inbox { seq = 1 }) then failwith "late push rejected";
  let late_items = Atomic.get inbox.items in
  if List.length drained_before_late_push <> 1 || List.length late_items <> 1 then
    failwith "negative fixture did not expose missing close state";
  Printf.printf "detected_missing_close_contract late_items=%d\n%!"
    (List.length late_items)

