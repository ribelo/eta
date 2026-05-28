module Q = Eta_sql

module Events = struct
  module T = Q.Table.Make (struct
    let name = "events"
  end)

  include T
  let timestamp = column "timestamp" Q.int
end

let _bad_between =
  Q.Expr.between Events.timestamp 1000 "later"

