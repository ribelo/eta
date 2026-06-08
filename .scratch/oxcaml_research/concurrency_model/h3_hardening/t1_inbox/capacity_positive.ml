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
  let drain_after_close t = close t; Atomic.exchange t.items [] |> List.rev
end

let () =
  let inbox = Inbox.create ~capacity:3 in
  let accepted =
    List.init 6 (fun seq -> Inbox.push_bounded inbox { seq })
    |> List.filter Fun.id |> List.length
  in
  let drained = Inbox.drain_after_close inbox in
  if accepted <> 3 || List.length drained <> 3 then
    failwith "capacity bound not observed";
  if Atomic.get inbox.count <> 3 then
    failwith "count changed before worker drain resets it";
  Printf.printf "capacity accepted=%d rejected=%d\n%!" accepted (6 - accepted)

