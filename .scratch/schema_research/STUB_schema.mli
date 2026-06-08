(** Proposed contract for a future [effet-schema] companion package.

    This is not wired into Dune. It records the second-pass decision:
    schema/codec values are pure and reusable; effectful validation is attached
    at decode boundaries so OCaml values stay generalisable and idiomatic. *)

type json
(** Abstract JSON value. The implementation should provide adapters for Yojson
    and possibly Ezjsonm, rather than forcing one JSON library into Effet core. *)

type issue = {
  path : string list;
  message : string;
}
(** Structured decode/validation issue. Paths are outermost-to-innermost field
    names or array indexes. *)

type error = [ `Decode of issue list ]
(** Typed Effet error used by schema decoders. *)

module Schema : sig
  type 'a t
  (** Pure schema/codec value.

      A schema can decode JSON, encode values, produce JSON Schema metadata,
      provide example values for tests, and derive equality. It does not carry
      an Effet environment channel. Effectful policies are layered by
      {!decode_with_policy}. *)

  val string : string t
  val bool : bool t
  val int : int t
  val float : float t

  val array : 'a t -> 'a list t
  val option : 'a t -> 'a option t

  val enum : name:string -> (string * 'a) list -> equal:('a -> 'a -> bool) -> 'a t
  (** String-backed enum/closed variant schema. *)

  val tagged_union :
    name:string ->
    tag:string ->
    ('a case) list ->
    equal:('a -> 'a -> bool) ->
    'a t
  (** Tagged union schema for OCaml variants. *)

  and 'a case

  val case :
    tag:string ->
    decode:(json -> ('a, issue list) result) ->
    encode:('a -> json option) ->
    'a case

  val lazy_ : (unit -> 'a t) -> 'a t
  (** Recursive schema knot. Used for trees and mutually-recursive domains. *)

  type ('record, 'field) field

  val required :
    string -> 'field t -> ('record -> 'field) -> ('record, 'field) field

  val optional :
    string -> 'field t -> ('record -> 'field option) -> ('record, 'field option) field

  val record4 :
    name:string ->
    ('a -> 'b -> 'c -> 'd -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    ('record, 'd) field ->
    equal:('record -> 'record -> bool) ->
    samples:'record list ->
    'record t

  val record3 :
    name:string ->
    ('a -> 'b -> 'c -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    equal:('record -> 'record -> bool) ->
    samples:'record list ->
    'record t

  val record6 :
    name:string ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    ('record, 'd) field ->
    ('record, 'e) field ->
    ('record, 'f) field ->
    equal:('record -> 'record -> bool) ->
    samples:'record list ->
    'record t
  (** Arity-specific builders are enough for v0. A ppx can later generate
      record schemas and remove this boilerplate without changing ['a t]. *)

  val refine : name:string -> ('a -> issue list) -> 'a t -> 'a t
  val transform :
    name:string ->
    decode:('encoded -> ('a, issue list) result) ->
    encode:('a -> 'encoded) ->
    'encoded t ->
    'a t
  (** Primitive for validated nominal domain types. In OCaml, define a
      domain-owned module with an abstract or private [type t] and build its
      schema with [transform]. Do not expose a TypeScript-style public
      wrapper. *)

  val decode :
    'a t -> json -> ('env, [> error ], 'a) Effet.Effect.t

  val decode_with_policy :
    'a t ->
    ('a -> ('env, [> error ], 'a) Effet.Effect.t) ->
    json ->
    ('env, [> error ], 'a) Effet.Effect.t
  (** Decode with an effectful validation/enrichment policy. This is where
      Effet env-row requirements enter the schema workflow. *)

  val encode : 'a t -> 'a -> json
  val json_schema : 'a t -> json
  val samples : 'a t -> 'a list
  val equal : 'a t -> 'a -> 'a -> bool
end

module type JSON_ADAPTER = sig
  type external_json

  val of_external : external_json -> json
  val to_external : json -> external_json
end
(** Adapter module sketch. Concrete Yojson/Ezjsonm adapters can live in
    optional sublibraries if dependency weight matters. *)
