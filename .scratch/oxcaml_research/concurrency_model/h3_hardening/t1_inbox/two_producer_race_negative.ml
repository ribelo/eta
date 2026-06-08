open! Portable

type item : immutable_data = { producer : int }

type inbox = {
  items : item list Atomic.t;
  count : int Atomic.t;
  capacity : int;
}

let create ~capacity = { items = Atomic.make []; count = Atomic.make 0; capacity }

let commit_push t item =
  Atomic.incr t.count;
  Atomic.update t.items ~pure_f:(fun items -> item :: items)

let () =
  let inbox = create ~capacity:1 in
  let p0_saw_space = Atomic.get inbox.count < inbox.capacity in
  let p1_saw_space = Atomic.get inbox.count < inbox.capacity in
  if p0_saw_space then commit_push inbox { producer = 0 };
  if p1_saw_space then commit_push inbox { producer = 1 };
  let count = Atomic.get inbox.count in
  let items = List.length (Atomic.get inbox.items) in
  if count <= inbox.capacity || items <= inbox.capacity then
    failwith "negative fixture did not expose stale capacity check";
  Printf.printf
    "detected_two_producer_capacity_race capacity=%d count=%d items=%d\n%!"
    inbox.capacity count items

