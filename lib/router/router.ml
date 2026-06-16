type 'a t = 'a Tree.t

let create () = Tree.empty ()
let insert router route value = Tree.insert router (Escape.of_string route) value

let[@inline always] at router path =
  match Tree.at_string router path with
  | Ok (value, params) -> Ok { Match.value; params }
  | Error e -> Error e

let find router path =
  match at router path with Ok { Match.value; _ } -> Some value | Error _ -> None

let remove router route = Tree.remove router (Escape.of_string route)
let merge ~into from = Tree.merge ~into from
let compress router = Tree.compress router
