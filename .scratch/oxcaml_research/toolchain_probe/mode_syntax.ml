let (identity @ portable) x = x
let value = identity 42
let () = if value <> 42 then failwith "identity changed"
