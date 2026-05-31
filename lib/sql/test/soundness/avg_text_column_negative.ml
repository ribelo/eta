module Q = Eta_sql

module Users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T

  let name = column "name" Q.text
end

let _bad_avg : (Users.table, float option) Q.Expr.t =
  Q.Expr.avg Q.Numeric.float Users.name
