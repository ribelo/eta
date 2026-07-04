let stats_counter ~name value =
  if value = max_int then Error (`Counter_overflow name) else Ok value

let bool_field name value = name ^ "=" ^ string_of_bool value
