type child = { id : int }

let scoped (body : child @ local -> int) =
  let child = { id = 1 } in
  body child

let ok () = scoped (fun child -> child.id)
let () = if ok () <> 1 then failwith "unexpected child id"

