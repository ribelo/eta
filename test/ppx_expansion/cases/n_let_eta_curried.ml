module Eta =
  struct
    module Effect =
      struct
        let fn _pos _name body = body
        let pure x = x
      end
  end
let%eta f x y z = Eta.Effect.pure (x, y, z)
