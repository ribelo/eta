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
end

module Comments = struct
  module T = Q.Table.Make (struct
    let name = "comments"
  end)

  include T
end

let _bad_column : (Posts.table * Comments.table, int) Q.column =
  Q.Scope.column Q.Scope.right Users.id
