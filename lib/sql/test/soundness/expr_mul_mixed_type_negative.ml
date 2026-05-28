module Q = Eta_sql

module Rects = struct
  module T = Q.Table.Make (struct
    let name = "rects"
  end)

  include T
  let width = column "width" Q.int
  let ratio = column "ratio" Q.float
end

let _bad_arithmetic =
  Q.Expr.mul (Q.Expr.col Rects.width) (Q.Expr.col Rects.ratio)

