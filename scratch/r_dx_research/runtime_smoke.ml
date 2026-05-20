let check name actual =
  if actual <> Dx_common.expected then
    failwith (Printf.sprintf "%s expected %d got %d" name Dx_common.expected actual)

let () =
  check "env-row" (Env_top.run ());
  check "args" (Args_top.run ());
  check "bag" (Bag_top.run ());
  Printf.printf "r-dx smoke tests passed\n%!"
