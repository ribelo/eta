(** Pure schemas and Eta-shaped decode policies.

    [eta-schema] is a companion package, not part of Eta core. A schema is
    a reusable value describing a data contract: it can decode JSON, encode a
    typed value, and derive equality. Decode and encode failures are
    represented as typed Eta failures. Effectful validation is attached at
    the decode boundary so the environment channel remains an ordinary Eta
    object row. *)

module Json : sig
  type number =
    | Int of int
    | Intlit of string
    | Float of float

  type t =
    | Null
    | Bool of bool
    | Number of number
    | String of string
    | Array of t list
    | Object of (string * t) list

  val null : t
  val bool : bool -> t
  val number : float -> t
  val int : int -> t
  val intlit : string -> t
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

type path_segment =
  | Field of string
  | Index of int

type issue_kind =
  | Type_mismatch of {
      expected : string;
      got : string;
    }
  | Missing_field of string
  | Custom of string
  | Refinement_failed of {
      name : string;
      reason : string;
    }

type issue = {
  path : path_segment list;
  schema_name : string option;
  kind : issue_kind;
}
(** A structured decode or validation problem.

    [path] is ordered from the outermost field/index to the innermost
    field/index. [schema_name] identifies the schema surface that produced the
    issue when the schema is named. [kind] is intended for programmatic
    classification; use {!render_issue} only for human-readable text. *)

type error = [ `Decode of issue list | `Encode of issue list ]
(** Typed Eta error emitted by schema codecs. *)

val issue : ?path:path_segment list -> ?schema_name:string -> string -> issue
val type_mismatch :
  ?path:path_segment list ->
  ?schema_name:string ->
  expected:string ->
  got:string ->
  unit ->
  issue
val missing_field : ?path:path_segment list -> ?schema_name:string -> string -> issue
val at : path_segment -> issue list -> issue list
val at_field : string -> issue list -> issue list
val at_index : int -> issue list -> issue list
val render_issue : issue -> string
val render_issues : issue list -> string
val issue_to_json_pointer : issue -> string

module Eta_schema : sig
  type 'a t
  (** Pure schema/codec value.

      Eta_schema values do not carry an Eta environment. Use
      {!decode_with_policy} for effectful validation that needs services. *)

  val string : string t
  val bool : bool t
  val int : int t
  val float : float t
  val json : json t
  (** Identity schema for arbitrary JSON values. Its provider JSON Schema is
      unconstrained. *)

  val json_object : (string * json) list t
  (** Free-form JSON object schema. Provider metadata permits arbitrary
      properties while runtime decoding rejects non-object values. *)

  val array : 'a t -> 'a list t
  val option : 'a t -> 'a option t

  val enum :
    name:string -> (string * 'a) list -> equal:('a -> 'a -> bool) -> 'a t
  (** String-backed closed variant schema. *)

  type 'a case

  val case :
    tag:string ->
    decode:(json -> ('a, issue list) result) ->
    encode:('a -> (json option, issue list) result) ->
    'a case

  val tagged_union :
    name:string ->
    tag:string ->
    'a case list ->
    equal:('a -> 'a -> bool) ->
    'a t
  (** Tagged-union schema for ordinary OCaml variants. Case encoders return
      [Ok None] when the value belongs to another case and [Error issues] when
      the selected case cannot encode its payload. *)

  val lazy_ : (unit -> 'a t) -> 'a t
  (** Recursive schema knot. *)

  val union : name:string -> 'a t list -> equal:('a -> 'a -> bool) -> 'a t
  (** Untagged union tried in declaration order. The derived provider schema
      uses [anyOf]. *)

  val custom :
    equal:('a -> 'a -> bool) ->
    decode:(json -> ('a, issue list) result) ->
    encode:('a -> (json, issue list) result) ->
    json_schema:json ->
    ?object_fields:string list ->
    unit ->
    'a t
  (** Build a schema from explicit pure codecs and provider metadata. Prefer
      ordinary combinators when they can express the same contract. *)

  type ('record, 'field) field

  val required :
    string -> 'field t -> ('record -> 'field) -> ('record, 'field) field

  val optional :
    string ->
    'field t ->
    ('record -> 'field option) ->
    ('record, 'field option) field

  val record0 :
    name:string ->
    'record ->
    equal:('record -> 'record -> bool) ->
    unit ->
    'record t

  val record1 :
    name:string ->
    ('a -> 'record) ->
    ('record, 'a) field ->
    equal:('record -> 'record -> bool) ->
    unit ->
    'record t

  val record2 :
    name:string ->
    ('a -> 'b -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    equal:('record -> 'record -> bool) ->
    unit ->
    'record t

  val record3 :
    name:string ->
    ('a -> 'b -> 'c -> 'record) ->
    ('record, 'a) field ->
    ('record, 'b) field ->
    ('record, 'c) field ->
    equal:('record -> 'record -> bool) ->
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
    unit ->
    'record t
  (** Arity-specific builders are the v0 hand-written product API. A PPX can
      generate these calls later without changing ['a t]. *)

  type 'record member

  val required_member :
    string ->
    'field t ->
    get:('record -> 'field) ->
    set:('record -> 'field -> 'record) ->
    'record member

  val optional_member :
    string ->
    'field t ->
    get:('record -> 'field option) ->
    set:('record -> 'field option -> 'record) ->
    'record member

  val record_fields :
    name:string ->
    empty:'record ->
    equal:('record -> 'record -> bool) ->
    'record member list ->
    'record t
  (** Dynamic-arity record builder for hand-written large product schemas.
      Members carry typed getters and setters; no heterogeneous values escape. *)

  val refine : name:string -> ('a -> issue list) -> 'a t -> 'a t

  val describe : string -> 'a t -> 'a t
  (** Attach a JSON Schema description without changing codec behavior. *)

  val with_keyword : string -> json -> 'a t -> 'a t
  (** Attach or replace one JSON Schema keyword. Validation constraints should
      also be represented by [refine] so provider metadata and runtime
      validation remain one composed schema value. *)

  val closed : 'a t -> 'a t
  (** Reject fields not declared by an object record schema and derive
      [additionalProperties: false]. Raises [Invalid_argument] for non-object
      schemas. *)

  val json_schema : 'a t -> json
  (** Derive provider-facing JSON Schema from this codec value. *)

  val transform :
    name:string ->
    equal:('a -> 'a -> bool) ->
    decode:('encoded -> ('a, issue list) result) ->
    encode:('a -> 'encoded) ->
    'encoded t ->
    'a t
  (** Bidirectional schema transformation.

      This is the primitive for validated nominal types in OCaml. Prefer a
      domain-owned module with an abstract or private [type t] and a schema
      built from [transform], rather than a TypeScript-style public wrapper. *)

  val decode_result : 'a t -> json -> ('a, issue list) result
  val decode :
    'a t -> json -> ('a, [> `Decode of issue list ] as 'err) Eta.Effect.t
  val encode_result : 'a t -> 'a -> (json, issue list) result

  val decode_with_policy :
    'a t ->
    ('a -> ('b, [> `Decode of issue list ] as 'err) Eta.Effect.t) ->
    json ->
    ('b, 'err) Eta.Effect.t
  (** Decode with an effectful validation/enrichment policy. This is where
      ordinary OCaml dependencies can be captured by the policy closure. *)

  val encode :
    'a t -> 'a -> (json, [> `Encode of issue list ] as 'err) Eta.Effect.t
  val equal : 'a t -> 'a -> 'a -> bool
end

module type JSON_ADAPTER = sig
  type external_json

  val of_external : external_json -> (json, issue list) result
  val to_external : json -> external_json
end
(** Adapter contract for concrete JSON libraries such as Yojson or Ezjsonm.
    The core package intentionally does not force one JSON dependency. *)

module Make (A : JSON_ADAPTER) : sig
  val decode_result : 'a Eta_schema.t -> A.external_json -> ('a, issue list) result

  val decode :
    'a Eta_schema.t ->
    A.external_json ->
    ('a, [> `Decode of issue list ] as 'err) Eta.Effect.t

  val encode_result : 'a Eta_schema.t -> 'a -> (A.external_json, issue list) result

  val encode :
    'a Eta_schema.t ->
    'a ->
    (A.external_json, [> `Encode of issue list ] as 'err) Eta.Effect.t
end
(** Bind schemas to a concrete JSON representation through a {!JSON_ADAPTER}. *)
