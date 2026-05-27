module A = Eta_ai
module Codec = Eta_ai_openai_codec

type json = A.Json.t

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

module Json = A.Json

let decode_error_result ?raw message =
  Codec.decode_error_result ?raw ~provider:"openai" message

let parse_json raw = Codec.parse_json ~provider:"openai" raw
let raw_json_value label raw = Codec.schema_value ~provider:"openai" label raw
let schema_value = raw_json_value

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value ?strict ~name ~schema_json ()

let decode_provider_error_json ?status raw json =
  Codec.provider_error_json ?status ~raw ~provider:"openai" json

let decode_error ~status ~headers raw =
  Codec.decode_error ~provider:"openai" ~status ~headers raw
