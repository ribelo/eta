type bad : immutable_data = { count : int ref }

let value = { count = ref 0 }
let () = ignore value
