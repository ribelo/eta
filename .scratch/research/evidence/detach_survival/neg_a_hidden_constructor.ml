(* MUST FAIL when added to scratch/detach_survival/dune modules.

   Property: a concrete public GADT signature cannot hide an extra internal
   daemon constructor. Branch A therefore requires making Effect.t abstract, not
   merely deleting [val detach].

   Expected error shape:
   Signature mismatch:
   Type declarations do not match:
   The constructor [Daemon] is only present in the implementation.
*)

module _ : sig
  type ('env, 'err, 'a) t = Pure : 'a -> (_, _, 'a) t
  val pure : 'a -> ('env, 'err, 'a) t
end = struct
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t

  let pure value = Pure value
end
