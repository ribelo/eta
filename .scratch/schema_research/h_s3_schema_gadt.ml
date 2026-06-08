open Effet
open Fixture

module Schema : sig
  type ('a, 'encoded) t
  type ('a, 'brand) branded

  val string : (string, string) t
  val int : (int, int) t
  val list : ('a, 'encoded) t -> ('a list, 'encoded list) t
  val literal_string : string -> (string, string) t
  val custom :
    name:string ->
    decode:(Json.t -> ('a, issue list) result) ->
    encode:('a -> Json.t) ->
    json_schema:Json.t ->
    arbitrary:'a list ->
    equal:('a -> 'a -> bool) ->
    ('a, 'encoded) t
  val decode_result : ('a, 'encoded) t -> Json.t -> ('a, issue list) result
  val transform :
    name:string ->
    decode:('a -> ('b, issue list) result) ->
    encode:('b -> 'a) ->
    ('a, 'encoded) t ->
    ('b, 'encoded) t
  val refine :
    name:string -> ('a -> issue list) -> ('a, 'encoded) t -> ('a, 'encoded) t
  val brand :
    name:string ->
    ('a -> bool) ->
    ('a, 'encoded) t ->
    (('a, 'brand) branded, 'encoded) t
  val value : ('a, 'brand) branded -> 'a
  val decode : ('a, 'encoded) t -> Json.t -> ('env, [> `Decode of issue list ], 'a) Effect.t
  val encode : ('a, 'encoded) t -> 'a -> Json.t
  val json_schema : ('a, 'encoded) t -> Json.t
  val arbitrary : ('a, 'encoded) t -> 'a list
  val equal : ('a, 'encoded) t -> 'a -> 'a -> bool
end = struct
  type ('a, 'brand) branded = Brand of 'a

  type (_, _) t =
    | Codec : {
        name : string;
        decode : Json.t -> ('a, issue list) result;
        encode : 'a -> Json.t;
        json_schema : Json.t;
        arbitrary : 'a list;
        equal : 'a -> 'a -> bool;
      }
        -> ('a, 'encoded) t

  let value (Brand value) = value

  let custom ~name ~decode ~encode ~json_schema ~arbitrary ~equal =
    Codec { name; decode; encode; json_schema; arbitrary; equal }

  let decode_result (Codec c) = c.decode
  let encode (Codec c) = c.encode
  let json_schema (Codec c) = c.json_schema
  let arbitrary (Codec c) = c.arbitrary
  let equal (Codec c) = c.equal

  let decode schema json =
    match decode_result schema json with
    | Ok value -> Effect.pure value
    | Error issues -> Effect.fail (`Decode issues)

  let string =
    Codec
      {
        name = "string";
        decode =
          (function
          | Json.String s -> Ok s
          | json -> Error [ issue ("Expected string, got " ^ Json.to_string json) ]);
        encode = (fun s -> Json.String s);
        json_schema = Json.object_ [ ("type", Json.String "string") ];
        arbitrary = [ ""; "a" ];
        equal = String.equal;
      }

  let int =
    Codec
      {
        name = "int";
        decode =
          (function
          | Json.Number n when is_int_float n -> Ok (int_of_float n)
          | json -> Error [ issue ("Expected int, got " ^ Json.to_string json) ]);
        encode = (fun n -> Json.Number (float_of_int n));
        json_schema = Json.object_ [ ("type", Json.String "integer") ];
        arbitrary = [ 0; 1 ];
        equal = Int.equal;
      }

  let list item =
    let (Codec c) = item in
    Codec
      {
        name = c.name ^ " list";
        decode =
          (function
          | Json.Array xs ->
              let rec loop i acc = function
                | [] -> Ok (List.rev acc)
                | x :: xs -> (
                    match c.decode x with
                    | Ok value -> loop (i + 1) (value :: acc) xs
                    | Error issues -> Error (at (string_of_int i) issues))
              in
              loop 0 [] xs
          | json -> Error [ issue ("Expected array, got " ^ Json.to_string json) ]);
        encode = (fun xs -> Json.Array (List.map c.encode xs));
        json_schema = Json.object_ [ ("type", Json.String "array"); ("items", c.json_schema) ];
        arbitrary = [ []; c.arbitrary ];
        equal = List.equal c.equal;
      }

  let literal_string expected =
    Codec
      {
        name = "literal";
        decode =
          (function
          | Json.String s when String.equal s expected -> Ok s
          | json ->
              Error
                [
                  issue
                    (Printf.sprintf "Expected %S, got %s" expected (Json.to_string json));
                ]);
        encode = (fun s -> Json.String s);
        json_schema = Json.object_ [ ("const", Json.String expected) ];
        arbitrary = [ expected ];
        equal = String.equal;
      }

  let transform ~name ~decode ~encode schema =
    let (Codec c) = schema in
    Codec
      {
        name;
        decode =
          (fun json ->
            match c.decode json with Ok a -> decode a | Error issues -> Error issues);
        encode = (fun b -> c.encode (encode b));
        json_schema = c.json_schema;
        arbitrary =
          List.filter_map
            (fun sample -> match decode sample with Ok value -> Some value | Error _ -> None)
            c.arbitrary;
        equal = Stdlib.( = );
      }

  let refine ~name check schema =
    let (Codec c) = schema in
    Codec
      {
        c with
        name = c.name ^ "." ^ name;
        decode =
          (fun json ->
            match c.decode json with
            | Error issues -> Error issues
            | Ok value -> (
                match check value with [] -> Ok value | issues -> Error issues));
        json_schema =
          Json.object_ [ ("allOf", Json.Array [ c.json_schema ]); ("description", Json.String name) ];
      }

  let brand ~name pred schema =
    transform ~name
      ~decode:(fun value ->
        if pred value then Ok (Brand value)
        else Error [ issue ("Expected branded value " ^ name) ])
      ~encode:value schema
end

let finite_from_string =
  Schema.transform ~name:"finiteFromString"
    ~decode:(fun s ->
      match float_of_string_opt s with
      | Some n when Float.is_finite n -> Ok n
      | _ -> Error [ issue "Expected a finite number string" ])
    ~encode:string_of_float Schema.string

type user_id_brand

let user_id =
  Schema.brand ~name:"UserId"
    (fun s -> String.length s >= 3 && String.sub s 0 2 = "u_")
    Schema.string

let color =
  Schema.custom ~name:"color"
    ~decode:(function
      | Json.String s -> color_of_string s
      | json -> Error [ issue ("Expected color string, got " ^ Json.to_string json) ])
    ~encode:(fun color -> Json.String (color_to_string color))
    ~json_schema:
      (Json.object_
         [
           ("enum", Json.Array [ Json.String "red"; Json.String "green"; Json.String "blue" ]);
         ])
    ~arbitrary:[ Red; Green; Blue ] ~equal:color_equal

let person =
  let open Schema in
  let tags = list string in
  let decode json =
    match json with
    | Json.Object _ -> (
        let required key schema =
          match Json.find key json with
          | None -> Error [ issue ~path:[ key ] "Missing key" ]
          | Some value -> Result.map_error (at key) (decode_result schema value)
        in
        let optional key schema =
          match Json.find key json with
          | None -> Ok None
          | Some value ->
              Result.map (fun value -> Some value)
                (Result.map_error (at key) (decode_result schema value))
        in
        match
          ( required "name" string,
            required "age" int,
            optional "email" string,
            required "tags" tags )
        with
        | Ok name, Ok age, Ok email, Ok tags ->
            if String.length name = 0 then Error [ issue ~path:[ "name" ] "Expected length >= 1" ]
            else if age < 0 || age > 150 then
              Error [ issue ~path:[ "age" ] "Expected 0 <= value <= 150" ]
            else Ok { name; age; email; tags }
        | results ->
            let collect = function Ok _ -> [] | Error issues -> issues in
            let a, b, c, d = results in
            Error (collect a @ collect b @ collect c @ collect d))
    | json -> Error [ issue ("Expected object, got " ^ Json.to_string json) ]
  in
  custom ~name:"person" ~decode
    ~encode:
      (fun p ->
        let fields =
          [
            ("name", Json.String p.name);
            ("age", Json.Number (float_of_int p.age));
            ("tags", Json.Array (List.map (fun s -> Json.String s) p.tags));
          ]
        in
        let fields =
          match p.email with None -> fields | Some email -> ("email", Json.String email) :: fields
        in
        Json.Object fields)
    ~json_schema:
      (Json.object_
         [
           ("type", Json.String "object");
           ( "required",
             Json.Array [ Json.String "name"; Json.String "age"; Json.String "tags" ] );
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

let support = full_support

module type SCHEMA_SIG = sig
  module Schema : sig
    type ('a, 'encoded) t
    type ('a, 'brand) branded

    val decode :
      ('a, 'encoded) t -> Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], 'a) Effect.t

    val encode : ('a, 'encoded) t -> 'a -> Fixture.Json.t
    val json_schema : ('a, 'encoded) t -> Fixture.Json.t
    val arbitrary : ('a, 'encoded) t -> 'a list
    val equal : ('a, 'encoded) t -> 'a -> 'a -> bool
    val value : ('a, 'brand) branded -> 'a
  end

  type user_id_brand

  val finite_from_string : (float, string) Schema.t
  val user_id : ((string, user_id_brand) Schema.branded, string) Schema.t
  val color : (Fixture.color, string) Schema.t
  val person : (Fixture.person, Fixture.Json.t) Schema.t
  val support : Fixture.support
end

module _ : SCHEMA_SIG = struct
  module Schema = Schema
  type nonrec user_id_brand = user_id_brand

  let finite_from_string = finite_from_string
  let user_id = user_id
  let color = color
  let person = person
  let support = support
end
