(* Type error deep inside the body; location must stay on the bad subexpr. *)
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
let%eta f () =
  let _ = 1 + "x" in
  Eta.Effect.pure ()
