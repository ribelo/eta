module Eta =
  struct
    module Effect =
      struct
        let fn _pos _name body = body
        let pure x = x
      end
  end
let f x = Eta.Effect.pure x [@@eta.trace]
