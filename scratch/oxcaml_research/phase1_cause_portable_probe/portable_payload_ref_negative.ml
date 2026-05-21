open! Portable

let counter = ref 0
let bad = Effet.Cause.Portable.Fail (fun () -> !counter)
let () = ignore bad
