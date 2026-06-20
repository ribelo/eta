type t = (string * string) list

let empty = []
let to_list t = t
let of_list t = t
let of_rev_list t = List.rev t
let get t name = List.assoc_opt name t
let add t name value = (name, value) :: t
