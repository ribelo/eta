(** Yojson adapter for {!Eta_schema}. *)

type external_json = Yojson.Safe.t

val of_yojson :
  external_json -> (Eta_schema.json, Eta_schema.issue list) result

val to_yojson : Eta_schema.json -> external_json

val decode_result :
  'a Eta_schema.Eta_schema.t ->
  external_json ->
  ('a, Eta_schema.issue list) result

val decode :
  'a Eta_schema.Eta_schema.t ->
  external_json ->
  ('a, [> `Decode of Eta_schema.issue list ]) Eta.Effect.t

val encode_result :
  'a Eta_schema.Eta_schema.t ->
  'a ->
  (external_json, Eta_schema.issue list) result

val encode :
  'a Eta_schema.Eta_schema.t ->
  'a ->
  (external_json, [> `Encode of Eta_schema.issue list ]) Eta.Effect.t
