let () =
  let value_result = Value_passing.run () in
  let reader_result = Reader_port.run () in
  if value_result <> reader_result then
    failwith "ports returned different results";
  let first, second = value_result in
  Format.printf "race:%s,%s both-released=true@." first second
