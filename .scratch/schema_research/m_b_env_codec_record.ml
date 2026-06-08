open Effet
open Fixture
open Migration_fixture

module Base = M_a_pure_schema_effect_policy

module Codec = struct
  type ('env, 'a) t = {
    decode : Json.t -> ('env, [ `Decode of issue list ], 'a) Effect.t;
    encode : 'a -> Json.t;
    json_schema : Json.t;
    samples : 'a list;
    equal : 'a -> 'a -> bool;
  }

  let from_schema schema () =
    {
      decode = Base.Schema.decode schema;
      encode = Base.Schema.encode schema;
      json_schema = Base.Schema.json_schema schema;
      samples = Base.Schema.samples schema;
      equal = Base.Schema.equal schema;
    }

  let decode t = t.decode
  let encode t = t.encode
  let samples t = t.samples
  let equal t = t.equal
end

let config () : ('env, config) Codec.t = Codec.from_schema Base.config ()
let event () : ('env, event) Codec.t = Codec.from_schema Base.event ()
let menu () : ('env, menu) Codec.t = Codec.from_schema (Base.menu ()) ()

let config_with_policy () :
    (< feature_allowed : string -> bool ; .. >, config) Codec.t =
  {
    (config ()) with
    Codec.decode = Base.decode_config_with_policy;
  }

let support =
  {
    full_support with
    (* The value restriction forces unit-thunked codecs once env-polymorphic
       effects live in record fields. This is the key ergonomic regression. *)
    no_weak_env_values = false;
  }

module type ENV_CODEC_SIG = sig
  module Codec : sig
    type ('env, 'a) t

    val decode :
      ('env, 'a) t -> Fixture.Json.t -> ('env, [ `Decode of Fixture.issue list ], 'a) Effect.t

    val encode : ('env, 'a) t -> 'a -> Fixture.Json.t
    val samples : ('env, 'a) t -> 'a list
    val equal : ('env, 'a) t -> 'a -> 'a -> bool
  end

  val config : unit -> ('env, Migration_fixture.config) Codec.t

  val config_with_policy :
    unit -> (< feature_allowed : string -> bool ; .. >, Migration_fixture.config) Codec.t

  val support : Migration_fixture.support
end

module _ : ENV_CODEC_SIG = struct
  module Codec = Codec
  let config = config
  let config_with_policy = config_with_policy
  let support = support
end
