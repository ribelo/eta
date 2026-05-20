open Effet
open Fixture

module User = struct
  type t = person

  let of_json = H_s1_decode.person_parser

  let to_json p =
    let fields =
      [
        ("name", Json.String p.name);
        ("age", Json.Number (float_of_int p.age));
        ("tags", Json.Array (List.map (fun s -> Json.String s) p.tags));
      ]
    in
    Json.Object
      (match p.email with None -> fields | Some email -> ("email", Json.String email) :: fields)
end

module Schema = struct
  type ('a, 'encoded) t = {
    decode_ppx : Json.t -> ('a, issue list) result;
    encode_ppx : 'a -> Json.t;
    json_schema : Json.t;
    arbitrary : 'a list;
    equal : 'a -> 'a -> bool;
  }

  let from_ppx ~decode ~encode ~json_schema ~arbitrary ~equal =
    { decode_ppx = decode; encode_ppx = encode; json_schema; arbitrary; equal }

  let decode schema json =
    match schema.decode_ppx json with
    | Ok value -> Effect.pure value
    | Error issues -> Effect.fail (`Decode issues)

  let encode schema value = schema.encode_ppx value
  let json_schema schema = schema.json_schema
  let arbitrary schema = schema.arbitrary
  let equal schema = schema.equal

  let refine ~name check schema =
    {
      schema with
      decode_ppx =
        (fun json ->
          match schema.decode_ppx json with
          | Error issues -> Error issues
          | Ok value -> (
              match check value with [] -> Ok value | issues -> Error issues));
      json_schema =
        Json.object_
          [ ("allOf", Json.Array [ schema.json_schema ]); ("description", Json.String name) ];
    }
end

let person_schema =
  Schema.from_ppx ~decode:User.of_json ~encode:User.to_json
    ~json_schema:
      (Json.object_
         [
           ("type", Json.String "object");
           ("required", Json.Array [ Json.String "name"; Json.String "age"; Json.String "tags" ]);
           ( "properties",
             Json.Object
               [
                 ("name", Json.object_ [ ("type", Json.String "string") ]);
                 ("age", Json.object_ [ ("type", Json.String "integer") ]);
                 ("email", Json.object_ [ ("type", Json.String "string") ]);
                 ( "tags",
                   Json.object_
                     [
                       ("type", Json.String "array");
                       ("items", Json.object_ [ ("type", Json.String "string") ]);
                     ] );
               ] );
         ])
    ~arbitrary:[ person_ok ] ~equal:person_equal
  |> Schema.refine ~name:"person refinements" (fun person ->
         let name_issues =
           if String.length person.name > 0 then []
           else [ issue ~path:[ "name" ] "Expected length >= 1" ]
         in
         let age_issues =
           if person.age >= 0 && person.age <= 150 then []
           else [ issue ~path:[ "age" ] "Expected 0 <= value <= 150" ]
         in
         name_issues @ age_issues)

let support =
  {
    full_support with
    union = false;
    branding = false;
    transform = false;
    effectful_decode = false;
  }

module type PPX_SCHEMA_SIG = sig
  module User : sig
    type t = Fixture.person

    val of_json : Fixture.Json.t -> (t, Fixture.issue list) result
    val to_json : t -> Fixture.Json.t
  end

  module Schema : sig
    type ('a, 'encoded) t

    val decode :
      ('a, 'encoded) t -> Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], 'a) Effect.t

    val encode : ('a, 'encoded) t -> 'a -> Fixture.Json.t
    val json_schema : ('a, 'encoded) t -> Fixture.Json.t
    val arbitrary : ('a, 'encoded) t -> 'a list
    val equal : ('a, 'encoded) t -> 'a -> 'a -> bool
  end

  val person_schema : (Fixture.person, Fixture.Json.t) Schema.t
  val support : Fixture.support
end

module _ : PPX_SCHEMA_SIG = struct
  module User = User
  module Schema = Schema
  let person_schema = person_schema
  let support = support
end
