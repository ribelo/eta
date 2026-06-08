open Effet
open Fixture

module Brand : sig
  type ('a, 'brand) t

  val make : 'a -> ('a, 'brand) t
  val value : ('a, 'brand) t -> 'a
end = struct
  type ('a, 'brand) t = Brand of 'a

  let make value = Brand value
  let value (Brand value) = value
end

module Validate = struct
  type 'a t = 'a -> issue list

  let pass _ = []

  let both a b value = a value @ b value

  let min_length n s =
    if String.length s >= n then []
    else [ issue (Printf.sprintf "Expected length >= %d" n) ]

  let between ~min ~max n =
    if n >= min && n <= max then []
    else [ issue (Printf.sprintf "Expected %d <= value <= %d" min max) ]

  let run validator value =
    match validator value with [] -> Ok value | issues -> Error issues
end

module Decode = H_s1_decode.Decode

let validate_effect validator value =
  match Validate.run validator value with
  | Ok value -> Effect.pure value
  | Error issues -> Effect.fail (`Decode issues)

let person_validator person =
  let name_issues = Validate.min_length 1 person.name |> List.map (fun i -> { i with path = [ "name" ] }) in
  let age_issues = Validate.between ~min:0 ~max:150 person.age |> List.map (fun i -> { i with path = [ "age" ] }) in
  name_issues @ age_issues

let decode_person json =
  Effect.bind (validate_effect person_validator) (H_s1_decode.decode_person json)

module User_id : sig
  type brand
  type t = (string, brand) Brand.t

  val decode : Json.t -> ('env, [> `Decode of issue list ], t) Effect.t
  val value : t -> string
end = struct
  type brand
  type t = (string, brand) Brand.t

  let value = Brand.value

  let decode json =
    Effect.bind
      (fun s ->
        if String.length s >= 3 && String.sub s 0 2 = "u_" then
          Effect.pure (Brand.make s)
        else Effect.fail (`Decode [ issue "Expected user id branded as u_*" ]))
      (Decode.of_parser Decode.string json)
end

let support =
  {
    no_support with
    decode = true;
    struct_ = true;
    array = true;
    optional = true;
    refinement = true;
    branding = true;
    effectful_decode = true;
    cause_integration = true;
  }

module type DECODE_VALIDATE_SIG = sig
  module User_id : sig
    type brand
    type t = (string, brand) Brand.t

    val decode : Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], t) Effect.t
    val value : t -> string
  end

  val decode_person :
    Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], Fixture.person) Effect.t

  val support : Fixture.support
end

module _ : DECODE_VALIDATE_SIG = struct
  module User_id = User_id
  let decode_person = decode_person
  let support = support
end
