module Eta =
  struct
    module Effect =
      struct
        let fn _pos _name body = body
        let pure x = x
      end
  end
let%eta f ?(flag = false) x = Eta.Effect.pure (flag, x)
