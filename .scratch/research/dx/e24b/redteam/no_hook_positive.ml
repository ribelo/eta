let () =
  let driver = Eta.Schedule.start (Eta.Schedule.recurs 0) in
  match Eta.Schedule.step ~now_ms:0 ~input:() driver with
  | Eta.Schedule.Done metadata, _ -> assert (metadata.output = 0)
  | Eta.Schedule.Continue _, _ -> assert false
