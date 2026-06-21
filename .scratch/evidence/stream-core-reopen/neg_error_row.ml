(* Negative evidence for candidate B (public Channel): typed-error preservation.

   This is the Channel equivalent of the old neg_b test (which proved candidate
   A's Stream preserves its error row through [run]). Here we prove that a
   Channel carrying [`Boom] cannot be run into a sink expecting [`Other]:
   the polymorphic-variant row is preserved, and the mismatch is rejected at
   compile time.

   How to observe: build this file. It MUST fail with a type error of the form
   "These two variant types have no intersection". Record that error in the
   verdict. To keep it out of the default lab build, it lives in its own
   directory with its own dune stanza; build it explicitly:

     dune build --root .scratch evidence/stream-core-reopen/negs/neg_error_row.exe

   The build failure IS the evidence. *)

open Stream_core_reopen_common

type ('o, 'od, 'i, 'id, 'err) channel =
  | C_done of 'od
  | C_emit of 'o * ('o, 'od, 'i, 'id, 'err) channel
  | C_fail of 'err

let boom : (int, unit, _, _, [ `Boom ]) channel = C_fail `Boom

(* A run-into-fold whose sink demands a different error row. *)
let run_fold (f : 'acc -> 'a -> 'acc) (acc : 'acc)
    (c : ('a, 'od, 'i, 'id, 'err) channel) : ('acc * 'od, 'err) result =
  match c with
  | C_done d -> Ok (acc, d)
  | C_fail e -> Error e
  | C_emit (_, _) -> failwith "ignore"

(* The line below must be rejected: [boom] carries [`Boom], but the annotation
   demands a result whose error row is [`Other]. These two variant types have
   no intersection. *)
let _bad : (int list * unit, [ `Other ]) result =
  run_fold (fun acc x -> x :: acc) [] boom
