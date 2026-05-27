let repeat n f =
  for i = 1 to n do
    f i
  done

let make_value i =
  let value = Eta_redacted.make ~label:"bench" ("secret-" ^ string_of_int i) in
  ignore (Eta_redacted.value value)

let format_value i =
  let value = Eta_redacted.make ~label:"bench" ("secret-" ^ string_of_int i) in
  ignore (Format.asprintf "%a" Eta_redacted.pp value)

let compare_value i =
  let left = Eta_redacted.make (string_of_int i) in
  let right = Eta_redacted.make (string_of_int i) in
  ignore (Eta_redacted.equal String.equal left right)

let workloads =
  let item name run =
    { Bench_lib.name = "redacted." ^ name; run; samples = None }
  in
  [
    item "make_value.100k" (fun () -> repeat 100_000 make_value);
    item "format.10k" (fun () -> repeat 10_000 format_value);
    item "equal.100k" (fun () -> repeat 100_000 compare_value);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
