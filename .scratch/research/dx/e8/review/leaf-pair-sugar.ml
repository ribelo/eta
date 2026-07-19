open Eta

type error = [ `Missing_user of string ]

let load_user id =
  [%eta.result "user.lookup"
    (if String.equal id "" then Error (`Missing_user id)
     else Ok { id; name = "user:" ^ id })]
