let expected =
  ( Layer_research.Services.expected_result,
    true,
    true,
    [ "http-open@2" ] )

let check name actual =
  if actual <> expected then
    failwith (Printf.sprintf "%s: unexpected result" name)

let () =
  check "merge_explicit" (Layer_research.Merge_explicit.run ());
  check "gadt_presence_set" (Layer_research.Gadt_presence_set.run ());
  check "no_layer_baseline" (Layer_research.No_layer_baseline.run ());
  Printf.printf "layer research smoke tests passed\n%!"
