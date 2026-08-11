let before_publication : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())

let after_publication : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())

let set_before_publication hook =
  Atomic.exchange before_publication hook

let set_after_publication hook =
  Atomic.exchange after_publication hook

let run_before_publication () =
  (Atomic.get before_publication) ()

let run_after_publication () =
  (Atomic.get after_publication) ()
