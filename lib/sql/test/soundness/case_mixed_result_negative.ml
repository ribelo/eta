module Q = Eta_sql

module Students = struct
  module T = Q.Table.Make (struct
    let name = "students"
  end)

  include T
  let score = column "score" Q.int
end

let _bad_case =
  Q.Expr.(
    case [ (gt Students.score 90, text_lit "A") ] ~default:(int_lit 0))
