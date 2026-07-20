(* Attribute twin of the non-effect body case. *)
module Eta =
  struct
    module Effect =
      struct
        type ('a, 'err) t
        external fn :
          string * int * int * int -> string -> ('a, 'err) t -> ('a, 'err) t
          = "%identity"
      end
  end
let f () = 1 [@@eta.trace]
