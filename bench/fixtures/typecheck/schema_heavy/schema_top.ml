open Eta_schema

type event =
  | One of Schema_m01.t
  | Two of Schema_m02.t
  | Three of Schema_m03.t

let case_one =
  Eta_schema.case ~tag:"one"
    ~decode:(fun json -> Result.map (fun value -> One value) (Eta_schema.decode_result Schema_m01.schema json))
    ~encode:(function One value -> Result.map Option.some (Eta_schema.encode_result Schema_m01.schema value) | _ -> Ok None)

let case_two =
  Eta_schema.case ~tag:"two"
    ~decode:(fun json -> Result.map (fun value -> Two value) (Eta_schema.decode_result Schema_m02.schema json))
    ~encode:(function Two value -> Result.map Option.some (Eta_schema.encode_result Schema_m02.schema value) | _ -> Ok None)

let case_three =
  Eta_schema.case ~tag:"three"
    ~decode:(fun json -> Result.map (fun value -> Three value) (Eta_schema.decode_result Schema_m03.schema json))
    ~encode:(function Three value -> Result.map Option.some (Eta_schema.encode_result Schema_m03.schema value) | _ -> Ok None)

let event_schema =
  Eta_schema.tagged_union ~name:"schema_event" ~tag:"kind"
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

let decoded = Eta_schema.decode_result event_schema sample
