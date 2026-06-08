type bad : immutable_data = { run : unit -> int }

let counter = ref 0
let value = { run = (fun () -> !counter) }
let () = ignore value
