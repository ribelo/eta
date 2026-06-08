(* Predicted error: the required labelled argument ~sw is missing.

   Property defended: S-C stages cannot be materialised without an owning
   Eio.Switch.t. Every queue/fiber pipeline has a structured-concurrency owner. *)

let _ =
  S_c_eio_pipeline.Stream.spawn
    (S_c_eio_pipeline.Stream.range 1 3)
