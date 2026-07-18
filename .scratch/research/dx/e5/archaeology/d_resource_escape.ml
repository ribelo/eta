(* Archaeology D: return the acquired handle from with_resource.
   Eta-expanded to keep the value restriction out of the measurement.
   Predicted: COMPILES (no phantom on the handle; lifetime is runtime-managed). *)
open Eta

let program () =
  Effect.with_resource
    ~acquire:(Effect.pure "conn")
    ~release:(fun _conn -> Effect.unit)
    (fun conn -> Effect.pure conn)
