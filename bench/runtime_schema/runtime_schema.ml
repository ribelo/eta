open Eta
open Eta_schema

type record3 = { name : string; count : int; active : bool }
type record6 = { a : string; b : int; c : bool; d : float; e : string option; f : int }

type event =
  | Created of record3
  | Updated of record3
  | Deleted of string

type menu = { title : string; children : menu list }

let record3_schema =
  Schema.record3 ~name:"bench_record3"
    (fun name count active -> { name; count; active })
    (Schema.required "name" Schema.string (fun r -> r.name))
    (Schema.required "count" Schema.int (fun r -> r.count))
    (Schema.required "active" Schema.bool (fun r -> r.active))
    ~equal:( = ) ()

let refined_string =
  Schema.refine ~name:"non_empty"
    (fun s -> if String.length s > 0 then [] else [ issue "empty" ])
    Schema.string

let record6_schema =
  Schema.record6 ~name:"bench_record6"
    (fun a b c d e f -> { a; b; c; d; e; f })
    (Schema.required "a" refined_string (fun r -> r.a))
    (Schema.required "b" Schema.int (fun r -> r.b))
    (Schema.required "c" Schema.bool (fun r -> r.c))
    (Schema.required "d" Schema.float (fun r -> r.d))
    (Schema.optional "e" Schema.string (fun r -> r.e))
    (Schema.required "f" Schema.int (fun r -> r.f))
    ~equal:( = ) ()

let event_schema =
  let payload tag ctor =
    Schema.case ~tag
      ~decode:(fun json -> Result.map ctor (Schema.decode_result record3_schema json))
      ~encode:(function
        | Created r when String.equal tag "created" ->
            Result.map Option.some (Schema.encode_result record3_schema r)
        | Updated r when String.equal tag "updated" ->
            Result.map Option.some (Schema.encode_result record3_schema r)
        | _ -> Ok None)
  in
  let deleted =
    Schema.case ~tag:"deleted"
      ~decode:(fun json ->
        match Json.find "id" json with
        | Some (Json.String id) -> Ok (Deleted id)
        | _ -> Error [ missing_field "id" ])
      ~encode:(function
        | Deleted id -> Ok (Some (Json.object_ [ ("id", Json.string id) ]))
        | _ -> Ok None)
  in
  Schema.tagged_union ~name:"bench_event" ~tag:"kind"
    [ payload "created" (fun r -> Created r); payload "updated" (fun r -> Updated r); deleted ]
    ~equal:( = )

let rec menu_schema =
  lazy
    (Schema.record2 ~name:"menu"
       (fun title children -> { title; children })
       (Schema.required "title" Schema.string (fun r -> r.title))
       (Schema.required "children" (Schema.array (Schema.lazy_ (fun () -> Lazy.force menu_schema))) (fun r -> r.children))
       ~equal:( = ) ())

let string_int =
  Schema.transform ~name:"string_int" ~equal:Int.equal
    ~decode:(fun s -> try Ok (int_of_string s) with Failure _ -> Error [ issue "bad int" ])
    ~encode:string_of_int Schema.string

let record3_json =
  Json.object_
    [ ("name", Json.string "alpha"); ("count", Json.int 42); ("active", Json.bool true) ]

let record6_json =
  Json.object_
    [
      ("a", Json.string "alpha");
      ("b", Json.int 1);
      ("c", Json.bool true);
      ("d", Json.number 1.5);
      ("e", Json.string "optional");
      ("f", Json.int 2);
    ]

let event_jsons =
  [
    Json.object_ [ ("kind", Json.string "created"); ("name", Json.string "a"); ("count", Json.int 1); ("active", Json.bool true) ];
    Json.object_ [ ("kind", Json.string "updated"); ("name", Json.string "b"); ("count", Json.int 2); ("active", Json.bool false) ];
    Json.object_ [ ("kind", Json.string "deleted"); ("id", Json.string "abc") ];
  ]

let rec menu_json depth =
  if depth = 0 then Json.object_ [ ("title", Json.string "leaf"); ("children", Json.array []) ]
  else
    Json.object_
      [
        ("title", Json.string "node");
        ("children", Json.array [ menu_json (depth - 1); menu_json (depth - 1) ]);
      ]

let repeat n f =
  for i = 1 to n do
    f i
  done

let decode schema json =
  match Schema.decode_result schema json with
  | Ok _ -> ()
  | Error _ -> ()

let encode schema value =
  match Schema.encode_result schema value with
  | Ok _ -> ()
  | Error _ -> ()

let run_policy () =
  let deps = object method feature_allowed = true end in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let policy value =
    Effect.sync "policy" (fun () ->
        if deps#feature_allowed then value else value)
  in
  ignore (Runtime.run rt (Schema.decode_with_policy record3_schema policy record3_json)
    : (_, [> `Decode of issue list ]) Exit.t)

let workloads =
  let item name run =
    { Bench_lib.name = "eta_schema." ^ name; run; samples = None }
  in
  [
    item "decode.record3.simple" (fun () -> repeat 10_000 (fun _ -> decode record3_schema record3_json));
    item "decode.record6.refined" (fun () -> repeat 10_000 (fun _ -> decode record6_schema record6_json));
    item "decode.tagged_union.3" (fun () ->
        repeat 10_000 (fun i -> decode event_schema (List.nth event_jsons (i mod 3))));
    item "decode.recursive.menu" (fun () -> repeat 1_000 (fun _ -> decode (Lazy.force menu_schema) (menu_json 4)));
    item "decode.array.10" (fun () -> decode (Schema.array record3_schema) (Json.array (List.init 10 (fun _ -> record3_json))));
    item "decode.array.1000" (fun () -> decode (Schema.array record3_schema) (Json.array (List.init 1_000 (fun _ -> record3_json))));
    item "decode.transform.string_int" (fun () -> repeat 10_000 (fun _ -> decode string_int (Json.string "42")));
    item "decode_with_policy.explicit_deps" run_policy;
    item "decode.failure.record3" (fun () -> repeat 10_000 (fun _ -> decode record3_schema Json.null));
    item "encode.record3" (fun () -> repeat 10_000 (fun _ -> encode record3_schema { name = "a"; count = 1; active = true }));
    item "encode.record6" (fun () -> repeat 10_000 (fun _ -> encode record6_schema { a = "a"; b = 1; c = true; d = 1.0; e = Some "x"; f = 2 }));
    item "encode.tagged_union" (fun () -> repeat 10_000 (fun _ -> encode event_schema (Created { name = "a"; count = 1; active = true })));
    item "encode.recursive" (fun () -> repeat 1_000 (fun _ -> encode (Lazy.force menu_schema) { title = "root"; children = [] }));
    item "json_render.record3" (fun () -> repeat 10_000 (fun _ -> ignore (Json.to_string record3_json)));
    item "json_render.array.1000" (fun () -> ignore (Json.to_string (Json.array (List.init 1_000 (fun _ -> record3_json)))));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
