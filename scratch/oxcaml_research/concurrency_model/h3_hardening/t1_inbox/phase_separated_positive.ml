open! Portable

type item : immutable_data = { seq : int; payload : int }

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

  let drain_after_close t =
    if not (Atomic.get t.closed) then failwith "worker drained before close";
    Atomic.set t.count 0;
    Atomic.exchange t.items [] |> List.rev
end

let () =
  let inbox = Inbox.create ~capacity:64 in
  for seq = 0 to 31 do
    if not (Inbox.push_bounded inbox { seq; payload = seq * 2 }) then
      failwith "phase-separated push rejected below capacity"
  done;
  Inbox.close inbox;
  let drained = Inbox.drain_after_close inbox in
  let seqs = List.map (fun item -> item.seq) drained in
  if seqs <> List.init 32 Fun.id then failwith "drain did not preserve push order";
  if Atomic.get inbox.count <> 0 then failwith "count not reset after drain";
  Printf.printf "phase_separated accepted=%d drained=%d\n%!" 32 (List.length drained)

