module Q = Eta_sql

module Users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T
  let status = column "status" Q.text
end

let _bad_in_values =
  Q.Expr.in_values Users.status [ "active"; 1 ]

