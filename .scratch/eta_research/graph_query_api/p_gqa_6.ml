let rows =
  [
    ("string","Graph.Param.string \"name\" name","runtime if wrong constructor used","Clean");
    ("int64","Graph.Param.int \"id\" id","runtime if wrong constructor used","Clean");
    ("double","Graph.Param.float \"score\" score","runtime if wrong constructor used","Clean");
    ("bool","Graph.Param.bool \"active\" active","runtime if wrong constructor used","Clean");
    ("null","Graph.Param.null \"nickname\"","runtime nullable policy","Awkward");
    ("list","Graph.Param.list \"ids\" Graph.Param.int ids","runtime element compatibility","Awkward");
    ("map","Graph.Param.map \"filter\" [field \"country\" string; field \"active\" bool]","runtime field mismatch","Awkward");
    ("bytes","Graph.Param.bytes \"blob\" bytes","blocked by LadybugDB C API","Untested");
  ]

let () =
  print_endline "=== P-Gqa-6 Parameter Binding Ergonomics ===";
  List.iter
    (fun (ty, call, mismatch, verdict) ->
      Printf.printf "%s.call=%s\n%s.mismatch=%s\n%s.verdict=%s\n"
        ty call ty mismatch ty verdict)
    rows;
  print_endline "verdict=Primitive params are clean in the baseline and Branch B/E. Null/list/map need helpers but are acceptable. Bytes stays Untested until the driver finds a blob bind path.";
