(* Context-qualified generative identities.

   Every public identity is an immediate-friendly pair of a context stamp and a
   per-context counter value. Identities support equality, comparison, and
   formatting only; they expose no parsing and no lifecycle authority. *)

let context_stamp_source = Atomic.make 0
let fresh_context_stamp () = Atomic.fetch_and_add context_stamp_source 1

type stamp = int

type t = {
  stamp : stamp;
  id : int;
}

let make stamp id = { stamp; id }
let id t = t.id
let stamp t = t.stamp
let equal a b = Int.equal a.stamp b.stamp && Int.equal a.id b.id

let compare a b =
  match Int.compare a.stamp b.stamp with
  | 0 -> Int.compare a.id b.id
  | nonzero -> nonzero

let pp f t = Format.fprintf f "%d/%d" t.stamp t.id

module Context_id = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end

module Desired_revision = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end

module Target_revision = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end

module Instance_id = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end

module Generation_id = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end

module Episode_id = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end

module Fence_id = struct
  type nonrec t = t

  let equal = equal
  let compare = compare
  let pp = pp
end
