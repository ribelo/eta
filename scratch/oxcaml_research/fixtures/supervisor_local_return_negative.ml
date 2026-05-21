type child = { id : int }

let scoped (body : child @ local -> 'a) =
  let child = { id = 1 } in
  body child

let bad () = scoped (fun child -> child)

