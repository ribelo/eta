open! Portable

module Batch_inbox = struct
  type phase : immutable_data = Open | Closed

  type t : value mod portable contended = {
    capacity : int;
    phase : phase Atomic.t;
    count : int Atomic.t;
    items : int list Atomic.t;
  }

  let create capacity =
    { capacity; phase = Atomic.make Open; count = Atomic.make 0; items = Atomic.make [] }

  let push inbox value =
    match Atomic.get inbox.phase with
    | Closed -> false
    | Open ->
        if Atomic.get inbox.count >= inbox.capacity then false
        else (
          Atomic.incr inbox.count;
          Atomic.update inbox.items ~pure_f:(fun items -> value :: items);
          true)

  let close inbox = Atomic.set inbox.phase Closed

  let drain inbox =
    match Atomic.get inbox.phase with
    | Open -> Error "drain_before_close"
    | Closed -> Ok (List.rev (Atomic.get inbox.items))
end

let () =
  let inbox = Batch_inbox.create 2 in
  if not (Batch_inbox.push inbox 1) then failwith "initial push failed";
  let online_drain_rejected =
    match Batch_inbox.drain inbox with
    | Error "drain_before_close" -> true
    | _ -> false
  in
  Batch_inbox.close inbox;
  let push_after_close_rejected = not (Batch_inbox.push inbox 2) in
  match Batch_inbox.drain inbox with
  | Ok [ 1 ] when online_drain_rejected && push_after_close_rejected ->
      Printf.printf
        "h3_batch_inbox_online_negative online_push_take=false drain_requires_close=true push_after_close_rejected=true\n%!"
  | _ -> failwith "batch inbox negative did not prove online transport gap"

