let () =
  let value_result = Value_passing_4.run () in
  let reader_result = Reader_port_4.run () in
  if value_result <> reader_result then
    failwith "four-dependency ports returned different results";
  Format.printf "fourth-dependency:both-audited=true@."
