let a_no_handler id =
  let () = Handled_effect_r_channel.Handled_separate.b ("fetching " ^ id) in
  Handled_effect_r_channel.Handled_separate.c id

let _ = a_no_handler
