open Effet
open Fixture

module Decode = struct
  type 'a parser = Json.t -> ('a, issue list) result
  type error = [ `Decode of issue list ]

  let fail issues = Effect.fail (`Decode issues)

  let of_parser parser json =
    match parser json with Ok value -> Effect.pure value | Error issues -> fail issues

  let string = function
    | Json.String s -> Ok s
    | json -> Error [ issue ("Expected string, got " ^ Json.to_string json) ]

  let int = function
    | Json.Number n when is_int_float n -> Ok (int_of_float n)
    | json -> Error [ issue ("Expected int, got " ^ Json.to_string json) ]

  let list item = function
    | Json.Array xs ->
        let rec loop i acc = function
          | [] -> Ok (List.rev acc)
          | x :: xs -> (
              match item x with
              | Ok value -> loop (i + 1) (value :: acc) xs
              | Error issues -> Error (at (string_of_int i) issues))
        in
        loop 0 [] xs
    | json -> Error [ issue ("Expected array, got " ^ Json.to_string json) ]

  let required key parser json =
    match Json.find key json with
    | None -> Error [ issue ~path:[ key ] "Missing key" ]
    | Some value -> Result.map_error (at key) (parser value)

  let optional key parser json =
    match Json.find key json with
    | None -> Ok None
    | Some value -> Result.map (fun value -> Some value) (Result.map_error (at key) (parser value))
end

let person_parser json =
  let open Decode in
  match json with
  | Json.Object _ -> (
      match
        ( required "name" string json,
          required "age" int json,
          optional "email" string json,
          required "tags" (list string) json )
      with
      | Ok name, Ok age, Ok email, Ok tags -> Ok { name; age; email; tags }
      | results ->
          let collect = function Ok _ -> [] | Error issues -> issues in
          let a, b, c, d = results in
          Error (collect a @ collect b @ collect c @ collect d))
  | json -> Error [ issue ("Expected object, got " ^ Json.to_string json) ]

let decode_person json = Decode.of_parser person_parser json

let decode_person_effectful json =
  Effect.bind
    (fun person ->
      Effect.bind
        (fun accepted ->
          if accepted then Effect.pure person
          else Decode.fail [ issue "age rejected by effectful policy" ])
        (Effect.named "age_policy" (Effect.sync (fun env -> env#age_policy person.age))))
    (decode_person json)

let support =
  {
    no_support with
    decode = true;
    struct_ = true;
    array = true;
    optional = true;
    effectful_decode = true;
    cause_integration = true;
  }

module type DECODE_SIG = sig
  type error = [ `Decode of Fixture.issue list ]

  val decode_person :
    Fixture.Json.t -> ('env, [> error ], Fixture.person) Effet.Effect.t

  val decode_person_effectful :
    Fixture.Json.t ->
    (< age_policy : int -> bool ; .. >, [> error ], Fixture.person) Effet.Effect.t

  val support : Fixture.support
end

module _ : DECODE_SIG = struct
  type error = Decode.error

  let decode_person = decode_person
  let decode_person_effectful = decode_person_effectful
  let support = support
end
