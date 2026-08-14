type context

let drop_unique (_x : context @ unique) = ()
let drop_once (_f : (unit -> unit) @ once) = ()
