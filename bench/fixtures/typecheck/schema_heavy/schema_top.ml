open Schema

type event =
  | One of Schema_m01.t
  | Two of Schema_m02.t
  | Three of Schema_m03.t

let case_one =
  Schema.case ~tag:"one"
    ~decode:(fun json -> Result.map (fun value -> One value) (Schema.decode_result Schema_m01.schema json))
    ~encode:(function One value -> Result.map Option.some (Schema.encode_result Schema_m01.schema value) | _ -> Ok None)

let case_two =
  Schema.case ~tag:"two"
    ~decode:(fun json -> Result.map (fun value -> Two value) (Schema.decode_result Schema_m02.schema json))
    ~encode:(function Two value -> Result.map Option.some (Schema.encode_result Schema_m02.schema value) | _ -> Ok None)

let case_three =
  Schema.case ~tag:"three"
    ~decode:(fun json -> Result.map (fun value -> Three value) (Schema.decode_result Schema_m03.schema json))
    ~encode:(function Three value -> Result.map Option.some (Schema.encode_result Schema_m03.schema value) | _ -> Ok None)

let event_schema =
  Schema.tagged_union ~name:"schema_event" ~tag:"kind"
    [ case_one; case_two; case_three ] ~equal:( = )

let sample =
  Json.object_
    [
      ("kind", Json.string "one");
      ("a", Json.string "alpha");
      ("b", Json.int 1);
      ("c", Json.bool true);
      ("d", Json.number 1.5);
      ("e", Json.string "extra");
      ("f", Json.int 2);
    ]

let decoded = Schema.decode_result event_schema sample
