let literals =
  [
    ("ok_params", "MATCH (p:Person {name: $name}) RETURN p", ["name"], true);
    ("missing_param", "MATCH (p:Person {name: $name, id: $id}) RETURN p", ["name"], false);
    ("known_schema", "MATCH (p:Person)-[:KNOWS]->(c:Company) RETURN p,c", [], true);
    ("unknown_schema", "MATCH (x:Planet) RETURN x", [], false);
  ]

let contains s sub =
  let len_s = String.length s and len_sub = String.length sub in
  let rec loop i =
    i + len_sub <= len_s
    && (String.sub s i len_sub = sub || loop (i + 1))
  in
  len_sub = 0 || loop 0

let extract_params s =
  let is_name = function
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true
    | _ -> false
  in
  let rec loop i acc =
    if i >= String.length s then List.rev acc
    else if s.[i] = '$' then
      let j = ref (i + 1) in
      while !j < String.length s && is_name s.[!j] do incr j done;
      let name = String.sub s (i + 1) (!j - i - 1) in
      loop !j (name :: acc)
    else loop (i + 1) acc
  in
  List.sort_uniq String.compare (loop 0 [])

let known_labels = ["Person"; "Company"; "Post"; "City"]

let schema_ok literal =
  let labels = ["Person"; "Company"; "Post"; "City"; "Planet"] in
  List.for_all
    (fun label -> (not (contains literal (":" ^ label))) || List.mem label known_labels)
    labels

let () =
  print_endline "=== P-Gqa-4 Cypher Literal PPX Feasibility ===";
  List.iter
    (fun (name, literal, supplied, expected) ->
      let params = extract_params literal in
      let params_ok = List.for_all (fun p -> List.mem p supplied) params in
      let ok = params_ok && schema_ok literal in
      Printf.printf "%s.params=[%s]\n" name (String.concat "," params);
      Printf.printf "%s.params_ok=%b schema_ok=%b result=%b expected=%b assertion=%s\n"
        name params_ok (schema_ok literal) ok expected (if ok = expected then "pass" else "fail"))
    literals;
  print_endline "subprobe_1_parameter_validation=Clean";
  print_endline "subprobe_2_schema_cross_check=Awkward";
  print_endline "subprobe_3_return_shape_inference=Untested";
  print_endline "subprobe_3_blocker=Reliable RETURN/path/write inference needs a real Cypher parser or LadybugDB metadata; regex would silently accept bad literals.";
  print_endline "verdict=Literal PPX is viable only as parameter/schema lint. It should not be the primary typed surface for v0.1.";
