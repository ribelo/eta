open! Portable

type item : immutable_data = { seq : int }

module Inbox = struct
  type t = {
    items : item list Atomic.t;
    count : int Atomic.t;
    closed : bool Atomic.t;
    capacity : int;
  }

  let create ~capacity =
    {
      items = Atomic.make [];
      count = Atomic.make 0;
      closed = Atomic.make false;
      capacity;
    }

  let push_bounded t item =
    if Atomic.get t.closed || Atomic.get t.count >= t.capacity
    then false
    else (
      Atomic.incr t.count;
      Atomic.update t.items ~pure_f:(fun items -> item :: items);
      true)

  let close t = Atomic.set t.closed true
end

let () =
  let inbox = Inbox.create ~capacity:4 in
  if not (Inbox.push_bounded inbox { seq = 0 }) then failwith "initial push failed";
  Inbox.close inbox;
  if Inbox.push_bounded inbox { seq = 1 } then
    failwith "closed inbox accepted a late push";
  Printf.printf "closed_inbox_rejects_late_push=true\n%!"

