module Json = struct
  type t = String of string
end

type issue = { message : string }

let issue message = { message }

module Schema = struct
  type 'a t = {
    decode : Json.t -> ('a, issue list) result;
    encode : 'a -> Json.t;
    equal : 'a -> 'a -> bool;
  }

  let string =
    {
      decode = (function Json.String s -> Ok s);
      encode = (fun s -> Json.String s);
      equal = String.equal;
    }

  let transform ~decode ~encode ~equal schema =
    {
      decode =
        (fun json ->
          match schema.decode json with
          | Ok value -> decode value
          | Error issues -> Error issues);
      encode = (fun value -> schema.encode (encode value));
      equal;
    }
end

module User_id : sig
  type t

  val schema : t Schema.t
  val decode : Json.t -> (t, issue list) result
  val encode : t -> Json.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = User_id of string

  let make s =
    if String.length s >= 4 && String.sub s 0 4 = "usr_" then Ok (User_id s)
    else Error [ issue "Expected user_id" ]

  let value (User_id s) = s
  let equal a b = String.equal (value a) (value b)

  let schema =
    Schema.transform ~decode:make ~encode:value ~equal Schema.string

  let decode json = schema.decode json
  let encode value = schema.encode value
end

module Email : sig
  type t

  val schema : t Schema.t
  val decode : Json.t -> (t, issue list) result
  val encode : t -> Json.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = Email of string

  let make s =
    if String.contains s '@' then Ok (Email s)
    else Error [ issue "Expected email" ]

  let value (Email s) = s
  let equal a b = String.equal (value a) (value b)

  let schema =
    Schema.transform ~decode:make ~encode:value ~equal Schema.string

  let decode json = schema.decode json
  let encode value = schema.encode value
end

let use_user_id (_ : User_id.t) = ()

let scenario () =
  match (User_id.decode (Json.String "usr_1"), Email.decode (Json.String "a@b")) with
  | Ok id, Ok _mail ->
      use_user_id id;
      Json.String "usr_1" = User_id.encode id
  | _ -> false

module type SIG = sig
  module User_id : sig
    type t

    val schema : t Schema.t
    val decode : Json.t -> (t, issue list) result
    val encode : t -> Json.t
    val value : t -> string
    val equal : t -> t -> bool
  end

  module Email : sig
    type t

    val schema : t Schema.t
    val decode : Json.t -> (t, issue list) result
    val encode : t -> Json.t
    val value : t -> string
    val equal : t -> t -> bool
  end

  val use_user_id : User_id.t -> unit
  val scenario : unit -> bool
end

module _ : SIG = struct
  module User_id = User_id
  module Email = Email
  let use_user_id = use_user_id
  let scenario = scenario
end

