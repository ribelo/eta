module Eta = struct
  module Effect = struct
    let sync f = f ()
  end
end

module Eta_observability = struct
  let fn _pos _name body = body
  let named _name body = body
end

let _ = [%eta.sync "clock.now" (Sys.time ())]
