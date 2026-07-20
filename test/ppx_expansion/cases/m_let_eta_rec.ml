module Eta =
  struct
    module Effect =
      struct
        let fn _pos _name body = body
        let pure x = x
      end
  end
let%eta rec countdown n =
  if n <= 0 then Eta.Effect.pure () else countdown (n - 1)
