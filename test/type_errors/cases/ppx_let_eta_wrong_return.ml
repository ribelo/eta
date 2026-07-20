(* Body succeeds with string but binding is annotated as int effect. *)
module Eta =
  struct
    module Effect =
      struct
        type ('a, 'err) t
        external pure : 'a -> ('a, 'err) t = "%identity"
        external fn :
          string * int * int * int -> string -> ('a, 'err) t -> ('a, 'err) t
          = "%identity"
      end
  end
let%eta f () : (int, [ `E ]) Eta.Effect.t = Eta.Effect.pure "nope"
