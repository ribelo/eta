(* Non-effect body under let%eta — message quality is the finding. *)
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
let%eta f () = 1
