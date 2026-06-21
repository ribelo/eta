(* Minimal self-contained runtime used by the stream-core-reopen evidence lab.

   This module deliberately reimplements a tiny Effect model instead of
   depending on the real [eta] package, so the lab is reproducible without the
   OxCaml/nix gate. The only property that matters for the type-shape question
   is that the error channel is a polymorphic-variant row ['err], exactly like
   the real [('a, 'err) Eta.Effect.t] used by [lib/stream/eta_stream.mli]. *)

module Effect = struct
  type ('a, 'err) t = unit -> ('a, 'err) result

  let pure (a : 'a) : (_, 'err) t = fun () -> Ok a
  let fail (e : 'err) : (_, 'err) t = fun () -> Error e

  let bind (m : ('a, 'err) t) (f : 'a -> ('b, 'err) t) : ('b, 'err) t =
    fun () ->
      match m () with Error e -> Error e | Ok a -> f a ()

  let ( let* ) = bind
  let map f m = fun () -> match m () with Error e -> Error e | Ok a -> Ok (f a)
  let run m = m ()
end

let invalid_arg msg = invalid_arg msg
