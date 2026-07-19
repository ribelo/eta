open Eta

(* Tempting but dishonest sketch:

   let and_at left right continuation =
     left (fun resource1 ->
       right (fun resource2 ->
         continuation resource1 resource2))

   Here [left] and [right] are [with_resource] CPS functions. The only ordinary
   composition nests the second callback inside the first, so acquisition is
   serial and both resource lifetimes are hidden in continuation inversion. An
   [and@] operator cannot turn that serial CPS structure into concurrent shared
   scope ownership without implementing a new lifecycle protocol behind syntax.

   VERDICT: reject [and@]. [Effect.Scoped.with_2]/[with_3] honestly name the
   shared-scope operation, use [par] for acquisition, and leave release ownership
   with the existing scope machinery. *)

let _eta_surface_anchor = Effect.with_resource
