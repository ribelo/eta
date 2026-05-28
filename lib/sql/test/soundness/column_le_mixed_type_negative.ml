module Q = Eta_sql

module Scores = struct
  module T = Q.Table.Make (struct
    let name = "scores"
  end)

  include T
  let score = column "score" Q.int
  let status = column "status" Q.text
end

let _bad_order =
  Q.Expr.le_col Scores.score Scores.status

