type context

let consume : context @ unique -> unit = fun _ -> ()
let bad (x @ unique) = consume x; consume x
