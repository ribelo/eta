module Eta = struct
  module Effect = struct
    let fn _pos _name body = body
    let named _name body = body
    let sync_result f = f ()
  end
end

module Db = struct
  let find _db _id = Ok 1
end

let db = ()
let id = 1
let _ = [%eta.result "db.find" (Db.find db id)]
