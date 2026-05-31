module Q = Eta_sql

let _bad_arithmetic : (unit, string) Q.Expr.t =
  Q.Expr.add Q.Numeric.float (Q.Expr.text_lit "a") (Q.Expr.text_lit "b")
