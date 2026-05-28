module Q = Eta_sql

module Users = struct
  module T = Q.Table.Make (struct
    let name = "users"
  end)

  include T
  let id = column "id" Q.int
end

module Posts = struct
  module T = Q.Table.Make (struct
    let name = "posts"
  end)

  include T
  let author_id = column "author_id" Q.int
end

module Comments = struct
  module T = Q.Table.Make (struct
    let name = "comments"
  end)

  include T
  let post_id = column "post_id" Q.int
end

let _bad_source =
  Q.Source.(
    from Users.table
    |> join Posts.table
         ~on:
           Q.Expr.(
             eq_col (Q.Scope.column (Q.Scope.left Q.Scope.self) Users.id)
               (Q.Scope.column Q.Scope.right Comments.post_id)))
