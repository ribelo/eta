open Effet
open Fixture
open Migration_fixture

module Base = M_a_pure_schema_effect_policy

module User_id : sig
  type t = user_id

  val schema : t Base.Schema.t
  val value : t -> string
end = struct
  type t = user_id

  let schema = Base.user_id
  let value = Brand.value
end

module Email : sig
  type t = email

  val schema : t Base.Schema.t
  val value : t -> string
end = struct
  type t = email

  let schema = Base.email
  let value = Brand.value
end

module Config = struct
  type t = config

  let schema = Base.config
  let decode json = Base.Schema.decode schema json
  let encode value = Base.Schema.encode schema value
  let equal a b = Base.Schema.equal schema a b
end

module Event = struct
  type t = event

  let schema = Base.event
  let decode json = Base.Schema.decode schema json
  let encode value = Base.Schema.encode schema value
  let equal a b = Base.Schema.equal schema a b
end

module Menu = struct
  type t = menu

  let schema () = Base.menu ()
  let decode json = Base.Schema.decode (schema ()) json
  let encode value = Base.Schema.encode (schema ()) value
  let equal a b = Base.Schema.equal (schema ()) a b
end

let decode_config_with_policy = Base.decode_config_with_policy

let support = full_support

module type MODULE_FIRST_SIG = sig
  module Config : sig
    type t = Migration_fixture.config

    val decode : Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], t) Effect.t
    val encode : t -> Fixture.Json.t
    val equal : t -> t -> bool
  end

  module Event : sig
    type t = Migration_fixture.event

    val decode : Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], t) Effect.t
    val encode : t -> Fixture.Json.t
    val equal : t -> t -> bool
  end

  module Menu : sig
    type t = Migration_fixture.menu

    val decode : Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], t) Effect.t
    val encode : t -> Fixture.Json.t
    val equal : t -> t -> bool
  end

  val decode_config_with_policy :
    Fixture.Json.t ->
    (< feature_allowed : string -> bool ; .. >, [> `Decode of Fixture.issue list ], Migration_fixture.config)
    Effect.t

  val support : Migration_fixture.support
end

module _ : MODULE_FIRST_SIG = struct
  module Config = Config
  module Event = Event
  module Menu = Menu
  let decode_config_with_policy = decode_config_with_policy
  let support = support
end
