(* Effect_erasure is the audited bridge from private eff constructors to the
   public abstract Effect.t. Keep this cast here so public helper modules do
   not grow ad hoc Obj/%identity sites. *)

external effect_to_public : ('a, 'err) Effect_core.t -> ('a, 'err) Effect.t =
  "%identity"

let public_sync ~leaf_name ~footprint t sync_fn =
  effect_to_public
    (Effect_core.sync_frame ~leaf_name ~footprint (fun frame ->
           sync_fn frame.Effect_core.runtime.Runtime_core.contract t))
