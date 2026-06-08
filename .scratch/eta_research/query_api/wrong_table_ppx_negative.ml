module Q = Eta_sql

[%%eta.sql.table
type users = {
  id : int [@primary_key];
  name : string;
}]

[%%eta.sql.table
type posts = {
  id : int [@primary_key];
  user_id : int;
}]

let _bad =
  Q.Select.(from Users.table Posts.all |> compile)
