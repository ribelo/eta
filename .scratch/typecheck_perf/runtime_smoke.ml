let () =
  let value = Tp_top.run () in
  if value <= 0 then failwith (Printf.sprintf "unexpected value %d" value);
  Printf.printf "typecheck_perf smoke passed: %d\n%!" value
