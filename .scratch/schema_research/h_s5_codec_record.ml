open Effet
open Fixture

module Codec = struct
  type ('env, 'err, 'a) t = {
    decode : Json.t -> ('env, 'err, 'a) Effect.t;
    encode : 'a -> Json.t;
    json_schema : Json.t option;
    arbitrary : 'a list;
    equal : 'a -> 'a -> bool;
  }

  let decode t = t.decode
  let encode t = t.encode
  let json_schema t = t.json_schema
  let arbitrary t = t.arbitrary
  let equal t = t.equal

  let of_result ~decode ~encode ~json_schema ~arbitrary ~equal =
    {
      decode =
        (fun json ->
          match decode json with
          | Ok value -> Effect.pure value
          | Error issues -> Effect.fail (`Decode issues));
      encode;
      json_schema = Some json_schema;
      arbitrary;
      equal;
    }

  let refine check codec =
    {
      codec with
      decode =
        (fun json ->
          Effect.bind
            (fun value ->
              match check value with
              | [] -> Effect.pure value
              | issues -> Effect.fail (`Decode issues))
            (codec.decode json));
    }
end

module Brand : sig
  type ('a, 'brand) t

  val make : 'a -> ('a, 'brand) t
  val value : ('a, 'brand) t -> 'a
end = struct
  type ('a, 'brand) t = Brand of 'a

  let make value = Brand value
  let value (Brand value) = value
end

let encode_person p =
      let fields =
        [
          ("name", Json.String p.name);
          ("age", Json.Number (float_of_int p.age));
          ("tags", Json.Array (List.map (fun s -> Json.String s) p.tags));
        ]
      in
      Json.Object
        (match p.email with None -> fields | Some email -> ("email", Json.String email) :: fields)

let person_refinements person =
  let a =
    if String.length person.name > 0 then []
    else [ issue ~path:[ "name" ] "Expected length >= 1" ]
  in
  let b =
    if person.age >= 0 && person.age <= 150 then []
    else [ issue ~path:[ "age" ] "Expected 0 <= value <= 150" ]
  in
  a @ b

let person () : ('env, [> `Decode of issue list ], Fixture.person) Codec.t =
  {
    Codec.decode =
      (fun json ->
        match H_s1_decode.person_parser json with
        | Error issues -> Effect.fail (`Decode issues)
        | Ok value -> (
            match person_refinements value with
            | [] -> Effect.pure value
            | issues -> Effect.fail (`Decode issues)));
    encode = encode_person;
    json_schema =
      Some
        (Json.object_
           [
             ("type", Json.String "object");
             ("required", Json.Array [ Json.String "name"; Json.String "age"; Json.String "tags" ]);
           ]);
    arbitrary = [ person_ok ];
    equal = person_equal;
  }

let person_with_policy () =
  {
    (person ()) with
    Codec.decode =
      (fun json ->
        Effect.bind
          (fun person ->
            Effect.bind
              (fun ok ->
                if ok then Effect.pure person
                else Effect.fail (`Decode [ issue "age rejected by policy" ]))
              (Effect.named "age_policy" (Effect.sync (fun env -> env#age_policy person.age))))
          (Codec.decode (person ()) json));
  }

type user_id_brand

let user_id () :
    ('env, [> `Decode of issue list ], (string, user_id_brand) Brand.t) Codec.t =
  {
    Codec.decode =
      (function
      | Json.String s when String.length s >= 3 && String.sub s 0 2 = "u_" ->
          Effect.pure (Brand.make s)
      | json ->
          Effect.fail
            (`Decode [ issue ("Expected user id, got " ^ Json.to_string json) ]));
    encode = (fun id -> Json.String (Brand.value id));
    json_schema = Some (Json.object_ [ ("type", Json.String "string") ]);
    arbitrary = [ Brand.make "u_1" ];
    equal = (fun a b -> String.equal (Brand.value a) (Brand.value b));
  }

let color () : ('env, [> `Decode of issue list ], color) Codec.t =
  {
    Codec.decode =
      (function
      | Json.String s -> (
          match color_of_string s with
          | Ok color -> Effect.pure color
          | Error issues -> Effect.fail (`Decode issues))
      | json -> Effect.fail (`Decode [ issue ("Expected color, got " ^ Json.to_string json) ]));
    encode = (fun color -> Json.String (color_to_string color));
    json_schema =
      Some
        (Json.object_
           [
             ("enum", Json.Array [ Json.String "red"; Json.String "green"; Json.String "blue" ]);
           ]);
    arbitrary = [ Red; Green; Blue ];
    equal = color_equal;
  }

let support = full_support

module type CODEC_SIG = sig
  module Codec : sig
    type ('env, 'err, 'a) t

    val decode : ('env, 'err, 'a) t -> Fixture.Json.t -> ('env, 'err, 'a) Effect.t
    val encode : ('env, 'err, 'a) t -> 'a -> Fixture.Json.t
    val json_schema : ('env, 'err, 'a) t -> Fixture.Json.t option
    val arbitrary : ('env, 'err, 'a) t -> 'a list
    val equal : ('env, 'err, 'a) t -> 'a -> 'a -> bool
  end

  module Brand : sig
    type ('a, 'brand) t

    val value : ('a, 'brand) t -> 'a
  end

  type user_id_brand

  val person : unit -> ('env, [> `Decode of Fixture.issue list ], Fixture.person) Codec.t

  val person_with_policy :
    unit ->
    (< age_policy : int -> bool ; .. >, [> `Decode of Fixture.issue list ], Fixture.person)
    Codec.t

  val user_id :
    unit ->
    ('env, [> `Decode of Fixture.issue list ], (string, user_id_brand) Brand.t) Codec.t

  val color : unit -> ('env, [> `Decode of Fixture.issue list ], Fixture.color) Codec.t

  val support : Fixture.support
end

module _ : CODEC_SIG = struct
  module Codec = Codec
  module Brand = Brand
  type nonrec user_id_brand = user_id_brand

  let person = person
  let person_with_policy = person_with_policy
  let user_id = user_id
  let color = color
  let support = support
end
