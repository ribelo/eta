let tapped =
  Eta.Schedule.recurs 0 |> Eta.Schedule.tap_input (fun () -> ())

let () =
  let driver = Eta.Schedule.start tapped in
  ignore (Eta.Schedule.step ~now_ms:0 ~input:() driver)
