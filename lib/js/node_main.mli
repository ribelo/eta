(** Convenience entry point for Node.js programs. *)

val run_main : ('a, 'err) Effect.t -> 'a Js.Promise.t
(** [run_main eff] creates a fresh runtime, runs [eff], and returns a promise
    that resolves with the success value or rejects with the error cause. *)
