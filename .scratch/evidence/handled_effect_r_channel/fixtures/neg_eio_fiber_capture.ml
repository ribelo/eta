module H = Handled_effect_r_channel.Handled_separate
module S = Handled_effect_r_channel.Services

let capture_runtime_handler_in_eio_children () =
  let db = S.make_db "main" in
  let log = S.make_log () in
  H.run ~db ~log (fun db_h _log_h ->
    Eio_main.run @@ fun _env ->
    Eio.Fiber.both
      (fun () -> ignore (H.c db_h "left"))
      (fun () -> ignore (H.c db_h "right")))

let _ = capture_runtime_handler_in_eio_children
