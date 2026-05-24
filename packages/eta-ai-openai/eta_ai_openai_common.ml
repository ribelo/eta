module A = Eta_ai
module Codec = Eta_ai_openai_codec

type json = A.Json.t

type structured_output = Codec.structured_output = {
  name : string;
  schema_json : A.raw_json;
  strict : bool option;
}

module Json = A.Json

let decode_error_result ?raw message =
  Stdlib.Error (A.Decode_error { provider = "openai"; message; raw })

let parse_json raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message -> decode_error_result ~raw message

let raw_json_value label raw =
  match Json.parse raw with
  | Stdlib.Ok json -> Stdlib.Ok json
  | Stdlib.Error message ->
      decode_error_result ~raw
        (Printf.sprintf "%s must be valid JSON: %s" label message)

let schema_value label raw = raw_json_value label raw

let structured_output ?strict ~name ~schema_json () =
  Codec.structured_output ~schema_value ?strict ~name ~schema_json ()

let finish_reason = function
  | "stop" -> A.Stop
  | "length" -> A.Length
  | "tool_calls" -> A.Tool_calls
  | "content_filter" -> A.Content_filter
  | "error" -> A.Error
  | other -> A.Other other

let usage json =
  let input_tokens =
    match Json.int_member "prompt_tokens" json with
    | Some _ as value -> value
    | None -> Json.int_member "input_tokens" json
  in
  let output_tokens =
    match Json.int_member "completion_tokens" json with
    | Some _ as value -> value
    | None -> Json.int_member "output_tokens" json
  in
  let total_tokens = Json.int_member "total_tokens" json in
  {
    A.input_tokens;
    output_tokens;
    total_tokens;
    raw =
      [
        ("input_tokens", Option.value ~default:"" (Option.map string_of_int input_tokens));
        ( "output_tokens",
          Option.value ~default:"" (Option.map string_of_int output_tokens) );
        ("total_tokens", Option.value ~default:"" (Option.map string_of_int total_tokens));
      ];
  }

let provider_error ?status ?code ?raw message =
  A.Provider_error { provider = "openai"; status; code; message; raw }

let decode_provider_error_json ?status raw json =
  match Json.object_member "error" json with
  | Some error_json ->
      let message =
        Json.string_member "message" error_json
        |> Option.value ~default:"provider returned an error"
      in
      let code =
        match Json.scalar_string_member "code" error_json with
        | Some _ as value -> value
        | None -> Json.string_member "type" error_json
      in
      provider_error ?status ?code ~raw message
  | None -> provider_error ?status ~raw "provider returned an error"

let decode_error ~status ~headers:_ raw =
  match Json.parse raw with
  | Stdlib.Ok json -> decode_provider_error_json ?status:(Some status) raw json
  | Stdlib.Error _ ->
      provider_error ?status:(Some status) ~raw "provider returned an error"
