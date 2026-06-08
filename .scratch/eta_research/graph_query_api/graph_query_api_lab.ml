type verdict = Clean | Awkward | Escape_hatch | Fails

let verdict_to_string = function
  | Clean -> "Clean"
  | Awkward -> "Awkward"
  | Escape_hatch -> "Escape hatch"
  | Fails -> "Fails"

type query = {
  id : string;
  title : string;
  cypher : string;
}

let queries =
  [
    { id = "Q1"; title = "simple lookup";
      cypher = "MATCH (p:Person {name: $name}) RETURN p" };
    { id = "Q2"; title = "single-hop join with property filter";
      cypher = "MATCH (a:Person)-[:KNOWS]->(b:Person) WHERE a.age > $min_age RETURN a.name, b.name" };
    { id = "Q3"; title = "optional match";
      cypher = "MATCH (p:Person {id: $id}) OPTIONAL MATCH (p)-[:WORKS_AT]->(c:Company) RETURN p, c" };
    { id = "Q4"; title = "variable-length path";
      cypher = "MATCH path = (a:Person {id: $a})-[:KNOWS*1..6]->(b:Person {id: $b}) RETURN path" };
    { id = "Q5"; title = "multi-stage WITH";
      cypher = "MATCH (p:Person)-[:POSTED]->(post:Post) WITH p, count(post) AS posts WHERE posts > $min_posts RETURN p.name, posts" };
    { id = "Q6"; title = "aggregation";
      cypher = "MATCH (p:Person)-[:LIVES_IN]->(c:City) RETURN c.name, count(p) AS residents ORDER BY residents DESC LIMIT $limit" };
    { id = "Q7"; title = "list parameter";
      cypher = "MATCH (p:Person) WHERE p.id IN $ids RETURN p" };
    { id = "Q8"; title = "map parameter";
      cypher = "MATCH (p:Person) WHERE p.country = $filter.country AND p.active = $filter.active RETURN p" };
    { id = "Q9"; title = "bulk ingest via UNWIND";
      cypher = "UNWIND $rows AS row MERGE (p:Person {id: row.id}) SET p.name = row.name, p.age = row.age" };
    { id = "Q10"; title = "typed function call";
      cypher = "MATCH (a)-[r]->(b) WHERE type(r) = $rel_type RETURN a, type(r) AS rt, b" };
  ]

type candidate = {
  name : string;
  description : string;
  cells : (string * verdict * string * string) list;
}

let cell c qid =
  List.find (fun (id, _, _, _) -> String.equal id qid) c.cells

let count pred c =
  List.fold_left
    (fun acc (_, v, _, _) -> if pred v then acc + 1 else acc)
    0 c.cells

let candidate_a =
  {
    name = "A";
    description = "Pure typed SQL-style pipe builder";
    cells =
      [
        ("Q1", Clean,
         "Match.node Person.as_ \"p\" |> where (Person.name p = param name) |> return node p",
         "Linear lookup is readable and pipe-friendly.");
        ("Q2", Awkward,
         "Match.node Person.as_ \"a\" |> out KNOWS (node Person \"b\") |> where (Person.age a > param min_age) |> return [a.name; b.name]",
         "Works, but edge/node alternation inside a pipe already needs nested handles.");
        ("Q3", Awkward,
         "match_ p |> optional (out WORKS_AT company) |> return [node p; opt company]",
         "Optional match can be bolted on but makes the pipeline stateful.");
        ("Q4", Escape_hatch,
         "raw_pattern \"path = (a:Person {id: $a})-[:KNOWS*1..6]->(b:Person {id: $b})\"",
         "Variable-length named path breaks the linear node-first API.");
        ("Q5", Awkward,
         "match_ posted |> with_ [p; count post as posts] |> where (posts > param min_posts) |> return [p.name; posts]",
         "WITH is pipe-shaped, but typed aliases need a second expression language.");
        ("Q6", Clean,
         "match_ lives_in |> return [city.name; count person as residents] |> order_by desc residents |> limit param_limit",
         "Aggregation/order/limit are clause-like and pipe well.");
        ("Q7", Clean,
         "match_ person |> where (Person.id p in_ param_ids) |> return [node p]",
         "List parameter filter is clause-like.");
        ("Q8", Awkward,
         "match_ person |> where (Person.country p = param_map filter country && Person.active p = param_map filter active)",
         "Map projection needs special parameter-access combinators.");
        ("Q9", Escape_hatch,
         "raw \"UNWIND $rows AS row MERGE ... SET ...\"",
         "UNWIND/MERGE/SET is not naturally represented by the match-first builder.");
        ("Q10", Awkward,
         "match_any_edge \"a\" \"r\" \"b\" |> where (type_ r = param rel_type) |> return [node a; alias (type_ r) \"rt\"; node b]",
         "Works only after adding unlabelled node/rel and function-call helpers.");
      ];
  }

let candidate_b =
  {
    name = "B";
    description = "Hybrid pattern DSL plus pipeable clauses";
    cells =
      [
        ("Q1", Clean,
         "match_ Pattern.(node \"p\" Person ~props:[name := param name]) |> return [node \"p\"]",
         "Pattern DSL owns graph shape; clauses stay linear.");
        ("Q2", Clean,
         "match_ Pattern.(node \"a\" Person -- rel KNOWS --> node \"b\" Person) |> where (prop \"a\" age > param min_age) |> return [prop \"a\" name; prop \"b\" name]",
         "Single-hop pattern is compact.");
        ("Q3", Clean,
         "match_ p |> optional Pattern.(node \"p\" -- rel WORKS_AT --> node \"c\" Company) |> return [node \"p\"; nullable_node \"c\"]",
         "Optional match is a clause over the same pattern language.");
        ("Q4", Clean,
         "match_ Pattern.(path \"path\" (node \"a\" Person -- rel KNOWS ~hops:(1,6) --> node \"b\" Person)) |> return [path \"path\"]",
         "Variable-length named path fits once pattern DSL has path and hops.");
        ("Q5", Clean,
         "match_ posted |> with_ [var \"p\"; count \"post\" as_ \"posts\"] |> where (var \"posts\" > param min_posts) |> return [prop \"p\" name; var \"posts\"]",
         "WITH chains are naturally pipeable.");
        ("Q6", Clean,
         "match_ lives_in |> return [prop \"c\" name; count \"p\" as_ \"residents\"] |> order_by desc \"residents\" |> limit limit",
         "Clause builder handles aggregation.");
        ("Q7", Clean,
         "match_ Pattern.(node \"p\" Person) |> where (prop \"p\" id |> in_ (param ids)) |> return [node \"p\"]",
         "List params are ordinary expressions.");
        ("Q8", Awkward,
         "where (prop \"p\" country = param_field filter country && prop \"p\" active = param_field filter active)",
         "Map params are possible but introduce stringly field access unless schema-typed.");
        ("Q9", Awkward,
         "unwind rows \"row\" |> merge Pattern.(node \"p\" Person ~props:[id := field \"row\" id]) |> set [prop \"p\" name := field \"row\" name; prop \"p\" age := field \"row\" age]",
         "Expressible, but this adds non-pattern write clauses.");
        ("Q10", Clean,
         "match_ Pattern.(anon_node \"a\" -- rel_var \"r\" --> anon_node \"b\") |> where (type_ \"r\" = param rel_type) |> return [node \"a\"; type_ \"r\" as_ \"rt\"; node \"b\"]",
         "Unlabelled nodes and type(r) fit expression helpers.");
      ];
  }

let candidate_c =
  {
    name = "C";
    description = "Cypher literal PPX with parameter typing";
    cells =
      List.map
        (fun q ->
          let verdict =
            match q.id with
            | "Q4" | "Q9" -> Awkward
            | _ -> Clean
          in
          (q.id, verdict,
           Printf.sprintf "[%%cypher {|%s|}] ~params ~decode" q.cypher,
           if verdict = Clean then
             "Cypher remains itself; call-site is compact if PPX validation exists."
           else
             "Literal is compact, but return/path or write-shape inference needs substantial PPX support."))
        queries;
  }

let candidate_d =
  {
    name = "D";
    description = "Parameterized string plus typed decoder baseline";
    cells =
      List.map
        (fun q ->
          (q.id, Clean,
           Printf.sprintf "Graph.query conn ~cypher:{|%s|} ~params ~decode" q.cypher,
           "Smallest working surface; type safety lives in params and decoder, not Cypher authoring."))
        queries;
  }

let candidate_e =
  {
    name = "E";
    description = "Named pattern fragments plus raw Cypher clauses";
    cells =
      [
        ("Q1", Clean, "person_by_name |> return [node p]",
         "A reusable typed fragment covers common lookup.");
        ("Q2", Clean, "knows_pair |> where raw_expr \"a.age > $min_age\" |> return [p \"a.name\"; p \"b.name\"]",
         "Graph shape is typed; scalar predicate is literal.");
        ("Q3", Clean, "person_by_id |> optional works_at |> return [node p; nullable c]",
         "Optional reusable fragment is clean.");
        ("Q4", Clean, "path_between ~rel:KNOWS ~hops:(1,6) |> return [path]",
         "Named path fragment is cleaner than general builder syntax.");
        ("Q5", Awkward, "posted_fragment |> raw_clause \"WITH p, count(post) AS posts\" |> where raw_expr \"posts > $min_posts\"",
         "WITH remains mostly literal.");
        ("Q6", Awkward, "lives_in_fragment |> raw_return_order_limit ...",
         "Aggregation is less typed than Branch B.");
        ("Q7", Clean, "person |> where raw_expr \"p.id IN $ids\" |> return [node p]",
         "List params are fine through literal predicate.");
        ("Q8", Clean, "person |> where raw_expr \"p.country = $filter.country AND p.active = $filter.active\"",
         "Map param stays Cypher-shaped.");
        ("Q9", Clean, "raw_write {|UNWIND $rows AS row MERGE ... SET ...|} ~params",
         "Bulk ingest is intentionally a raw write clause.");
        ("Q10", Clean, "any_edge |> where raw_expr \"type(r) = $rel_type\" |> return [node a; expr \"type(r)\" as rt; node b]",
         "Pattern fragment plus literal type predicate is compact.");
      ];
  }

let candidates = [ candidate_a; candidate_b; candidate_c; candidate_d; candidate_e ]

let candidate_status c =
  let escapes = count (function Escape_hatch -> true | _ -> false) c in
  let fails = count (function Fails -> true | _ -> false) c in
  let clean = count (function Clean -> true | _ -> false) c in
  if escapes >= 3 || fails >= 3 then "Eliminated"
  else if clean >= 7 then "Survives"
  else "Survives with risk"

let print_cell qid c =
  let _, v, call, why = cell c qid in
  Printf.printf "%s | %s | %s | %s\n" c.name (verdict_to_string v) call why
