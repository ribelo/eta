let () =
  if not (B_b_abstract_newtype.scenario ()) then
    failwith "abstract newtype scenario";
  if not (B_c_witness_newtype.scenario ()) then
    failwith "witness newtype scenario";
  if not (B_d_private_abbrev.scenario ()) then
    failwith "private abbreviation scenario";
  print_endline "nominality scenarios passed"
