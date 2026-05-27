type record = { name : string; count : int }

let schema =
  Eta_schema.Eta_schema.record2 ~name:"bench_schema_test"
    (fun name count -> { name; count })
    (Eta_schema.Eta_schema.required "name" Eta_schema.Eta_schema.string (fun r -> r.name))
    (Eta_schema.Eta_schema.required "count" Eta_schema.Eta_schema.int (fun r -> r.count))
    ~equal:( = ) ()

let json =
  Eta_schema.Json.object_
    [ ("name", Eta_schema.Json.string "eta"); ("count", Eta_schema.Json.int 42) ]

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let decode_ok () =
  ignore (Eta_schema_test.decode_ok schema json)

let encode_ok () =
  ignore (Eta_schema_test.encode_ok schema { name = "eta"; count = 42 })

let roundtrip () =
  let value = Eta_schema_test.decode_ok schema json in
  ignore (Eta_schema_test.encode_ok schema value)

let workloads =
  let item name run =
    { Bench_lib.name = "schema_test." ^ name; run; samples = None }
  in
  [
    item "decode_ok.10k" (fun () -> repeat 10_000 decode_ok);
    item "encode_ok.10k" (fun () -> repeat 10_000 encode_ok);
    item "roundtrip.10k" (fun () -> repeat 10_000 roundtrip);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
