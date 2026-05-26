type record = { name : string; count : int }

let schema =
  Schema.Schema.record2 ~name:"bench_schema_test"
    (fun name count -> { name; count })
    (Schema.Schema.required "name" Schema.Schema.string (fun r -> r.name))
    (Schema.Schema.required "count" Schema.Schema.int (fun r -> r.count))
    ~equal:( = ) ()

let json =
  Schema.Json.object_
    [ ("name", Schema.Json.string "eta"); ("count", Schema.Json.int 42) ]

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let decode_ok () =
  ignore (Schema_test.decode_ok schema json)

let encode_ok () =
  ignore (Schema_test.encode_ok schema { name = "eta"; count = 42 })

let roundtrip () =
  let value = Schema_test.decode_ok schema json in
  ignore (Schema_test.encode_ok schema value)

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
