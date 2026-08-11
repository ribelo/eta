let after_consumer_claim : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())

let set_after_consumer_claim hook =
  Atomic.exchange after_consumer_claim hook

let run_after_consumer_claim () =
  (Atomic.get after_consumer_claim) ()
