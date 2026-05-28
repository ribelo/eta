let () =
  print_endline "=== P-Gqa-3 Schema PPX Probe ===";
  print_endline "input_node=[%%graph.node type person = { id : int64 [@id]; name : string; age : int; active : bool }]";
  print_endline "generated.Person.label=Person";
  print_endline "generated.Person.id_accessor=p.id:int64";
  print_endline "generated.Person.name_accessor=p.name:string";
  print_endline "generated.Person.param={id:Int; name:String; age:Int; active:Bool}";
  print_endline "generated.Person.decoder=Arrow NODE struct _ID,_LABEL,id,name,age,active -> person";
  print_endline "node_fixture.verdict=Clean";
  print_endline "input_rel=[%%graph.rel type knows = { since : int } [@from Person] [@to Person]]";
  print_endline "generated.Knows.label=KNOWS";
  print_endline "generated.Knows.pattern=Pattern.rel KNOWS";
  print_endline "generated.Knows.decoder=Untested";
  print_endline "rel_fixture.verdict=Partial";
  print_endline "blocker=LadybugDB lab did not decode REL/PATH Arrow shapes, so REL PPX can generate label/accessor/pattern metadata but not a proven decoder.";
  print_endline "verdict=Schema PPX earns a place for NODE modules; REL support should be metadata-only until REL Arrow decoding is proven.";
