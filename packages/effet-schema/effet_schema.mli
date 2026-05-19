(** Pure schemas and Effet-shaped decode policies.

    [effet-schema] is a companion package, not part of Effet core. A schema is
    a reusable value describing a data contract: it can decode JSON, encode a
    typed value, expose JSON Schema metadata, provide samples, and derive
    equality. Effectful validation is attached at the decode boundary so the
    environment channel remains an ordinary Effet object row. *)

module Json : sig
  type t =
    | Null
    | Bool of bool
    | Number of float
    | String of string
    | Array of t list
    | Object of (string * t) list

  val null : t
  val bool : bool -> t
  val number : float -> t
  val int : int -> t
  val string : string -> t
  val array : t list -> t
  val object_ : (string * t) list -> t

  val find : string -> t -> t option
  val equal : t -> t -> bool
  val to_string : t -> string
end
(** Minimal JSON representation used by the core package. Adapters keep
    dependency-specific JSON values outside user schemas. *)

type json = Json.t

type issue = {
  path : string list;
  message : string;
}
(** A structured decode or validation problem. [path] is ordered from the
    outermost field/index to the innermost field/index. *)

type error = [ `Decode of issue list ]
(** Typed Effet error emitted by schema decoders. *)

val issue : ?path:string list -> string -> issue
val at : string -> issue list -> issue list
val render_issue : issue -> string
val render_issues : issue list -> string

module Schema : sig
  type 'a t
  (** Pure schema/codec value.

      Schema values do not carry an Effet environment. Use
      {!decode_with_policy} for effectful validation that needs services. *)

  val string : string t
  val bool : bool t
  val int : int t
  val float : float t

  val array : 'a t -> 'a list t
  val option : 'a t -> 'a option t

  val enum :
    name:string -> (string * 'a) list -> equal:('a -> 'a -> bool) -> 'a t
  (** String-backed closed variant schema. *)

  type 'a case

  val case :
    tag:string ->
    decode:(json -> ('a, issue list) result) ->
    encode:('a -> json option) ->
    'a case

  val tagged_union :
    name:string ->
    tag:string ->
    'a case list ->
    equal:('a -> 'a -> bool) ->
    'a t
  (** Tagged-union schema for ordinary OCaml variants. *)

  val lazy_ : (unit -> 'a t) -> 'a t
  (** Recursive schema knot. *)

  type ('record, 'field) field

  val required :
    string -> 'field t -> ('record -> 'field) -> ('record, 'field) field

  val optional :
    string ->
    'field t ->
    ('record -> 'field option) ->
    ('record, 'field option) field

  val record1 :
    name:string ->
    ('a -> 'record) ->
    ('record, 'a) field ->
    equal:('record -> 'record -> bool) ->
    ?samples:'record list ->
    unit ->
    'record t

  val record2 :
    name:string ->
    ('a -> 'b -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    equal:('record -> 'record -> bool) ->
    ?samples:'record list ->
    unit ->
    'record t

  val record3 :
    name:string ->
    ('a -> 'b -> 'c -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    equal:('record -> 'record -> bool) ->
    ?samples:'record list ->
    unit ->
    'record t

  val record4 :
    name:string ->
    ('a -> 'b -> 'c -> 'd -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    ('record, 'd) field ->
    equal:('record -> 'record -> bool) ->
    ?samples:'record list ->
    unit ->
    'record t

  val record5 :
    name:string ->
    ('a -> 'b -> 'c -> 'd -> 'e -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    ('record, 'd) field ->
    ('record, 'e) field ->
    equal:('record -> 'record -> bool) ->
    ?samples:'record list ->
    unit ->
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
    ?samples:'record list ->
    unit ->
    'record t
  (** Arity-specific builders are the v0 hand-written product API. A PPX can
      generate these calls later without changing ['a t]. *)

  val refine : name:string -> ('a -> issue list) -> 'a t -> 'a t

  val transform :
    name:string ->
    ?equal:('a -> 'a -> bool) ->
    decode:('encoded -> ('a, issue list) result) ->
    encode:('a -> 'encoded) ->
    'encoded t ->
    'a t
  (** Bidirectional schema transformation.

      This is the primitive for validated nominal types in OCaml. Prefer a
      domain-owned module with an abstract or private [type t] and a schema
      built from [transform], rather than a TypeScript-style public wrapper. *)

  val decode_result : 'a t -> json -> ('a, issue list) result
  val decode : 'a t -> json -> ('env, [> error ] as 'err, 'a) Effet.Effect.t

  val decode_with_policy :
    'a t ->
    ('a -> ('env, [> error ] as 'err, 'a) Effet.Effect.t) ->
    json ->
    ('env, 'err, 'a) Effet.Effect.t
  (** Decode with an effectful validation/enrichment policy. This is where
      Effet env-row requirements enter schema workflows. *)

  val encode : 'a t -> 'a -> json
  val json_schema : 'a t -> json
  val samples : 'a t -> 'a list
  val equal : 'a t -> 'a -> 'a -> bool
end

module type JSON_ADAPTER = sig
  type external_json

  val of_external : external_json -> (json, issue list) result
  val to_external : json -> external_json
end
(** Adapter contract for concrete JSON libraries such as Yojson or Ezjsonm.
    The core package intentionally does not force one JSON dependency. *)
