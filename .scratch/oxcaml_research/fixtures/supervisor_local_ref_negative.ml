type child = { id : int }

let stash = ref None

let scoped (body : child @ local -> unit) =
  let child = { id = 1 } in
  body child

let bad () = scoped (fun child -> stash := Some child)

