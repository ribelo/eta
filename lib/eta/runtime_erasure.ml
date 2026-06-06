(* Runtime_erasure is the audited bridge between public abstract Eta types and
   their package-private representations. Keep representation casts here so
   Runtime.run does not grow new ad hoc Obj/%identity sites. The dynamic
   typed-failure key remains owned by Runtime_core; these casts only cross
   module abstraction boundaries inside the eta library. *)

external effect_of_public : ('a, 'err) Effect.t -> ('a, 'err) Effect_core.t =
  "%identity"

let erase_runtime_error (runtime : 'err Runtime_core.t) : Obj.t Runtime_core.t =
  (Obj.magic runtime : Obj.t Runtime_core.t)
