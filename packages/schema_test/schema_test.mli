(** Alcotest helpers for Eta Schema tests.

    This package extracts the reusable schema assertions that were previously
    local to [packages/eta-schema/test/run.ml]. It intentionally avoids
    property-based generators; those remain deferred to a later version. *)

type schema_error = Schema.error

val json_testable : Schema.Json.t Alcotest.testable
(** Testable for schema JSON values. *)

val issue_testable : Schema.issue Alcotest.testable
(** Testable for one rendered schema issue. *)

val issues_testable : Schema.issue list Alcotest.testable
(** Testable for rendered schema issue lists. *)

val run_effect : ('a, 'err) Eta.Effect.t -> ('a, 'err) result
(** Evaluate the pure Eta effect subset produced by Eta Schema helpers. *)

val expect_ok : ?name:string -> ('a, schema_error) result -> 'a
(** [expect_ok result] returns the value or fails with rendered schema issues. *)

val expect_decode_error :
  ?name:string -> ('a, schema_error) result -> Schema.issue list
(** [expect_decode_error result] extracts decode issues or fails the test. *)

val expect_encode_error :
  ?name:string -> ('a, schema_error) result -> Schema.issue list
(** [expect_encode_error result] extracts encode issues or fails the test. *)

val decode_ok :
  ?name:string -> 'a Schema.Schema.t -> Schema.Json.t -> 'a
(** [decode_ok schema json] decodes or fails with rendered issues. *)

val encode_ok :
  ?name:string -> 'a Schema.Schema.t -> 'a -> Schema.Json.t
(** [encode_ok schema value] encodes or fails with rendered issues. *)

val check_decode :
  'a Alcotest.testable ->
  ?name:string ->
  'a Schema.Schema.t ->
  Schema.Json.t ->
  'a ->
  unit
(** [check_decode testable schema json expected] asserts a decoded value. *)

val check_encode :
  ?name:string ->
  'a Schema.Schema.t ->
  'a ->
  Schema.Json.t ->
  unit
(** [check_encode schema value expected_json] asserts an encoded JSON value. *)

val check_roundtrip_json :
  ?name:string -> 'a Schema.Schema.t -> Schema.Json.t -> unit
(** [check_roundtrip_json schema json] decodes then encodes and compares JSON. *)
