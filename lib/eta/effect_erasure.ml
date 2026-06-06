(* Effect_erasure is the audited bridge from private effect constructors to the
   public abstract Effect.t. Keep this cast here so public helper modules do
   not grow ad hoc Obj/%identity sites. *)

external effect_to_public : ('a, 'err) Effect_core.t -> ('a, 'err) Effect.t =
  "%identity"
