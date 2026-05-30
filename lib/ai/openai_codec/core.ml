module A = Eta_ai
module Json = A.Json

type structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let structured_output ~schema_value ?strict ~name ~schema_json () =
  let trimmed = String.trim name in
  if String.equal trimmed "" then
    Stdlib.Error
      (A.Invalid_tool { name; message = "structured output name is required" })
  else
    match schema_value "structured output schema_json" schema_json with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok schema -> Stdlib.Ok { name = trimmed; schema; strict }

let decode_error_result = A.Json_helpers.decode_error_result
let parse_json = A.Json_helpers.parse_json
let schema_value = A.Json_helpers.schema_value

let result_all = A.Json_helpers.result_all

let unsupported ~provider feature =
  Stdlib.Error (A.Unsupported { provider; feature })

let non_empty_list ~provider label = function
  | [] -> unsupported ~provider (label ^ " must not be empty")
  | values -> Stdlib.Ok values

let positive_int_json ~provider label = function
  | None -> Stdlib.Ok None
  | Some value when value > 0 -> Stdlib.Ok (Some (Json.int value))
  | Some _ -> unsupported ~provider (label ^ " must be positive")

let optional_non_empty ~provider label = function
  | None -> Stdlib.Ok None
  | Some value when String.equal (String.trim value) "" ->
      unsupported ~provider (label ^ " must not be empty")
  | Some value -> Stdlib.Ok (Some value)

let embedding_encoding_format_json ~provider = function
  | None -> Stdlib.Ok None
  | Some ("float" | "base64" as value) -> Stdlib.Ok (Some (Json.string value))
  | Some _ ->
      unsupported ~provider "embedding encoding_format must be float or base64"

let temperature_json ~provider = function
  | None -> Stdlib.Ok None
  | Some value -> (
      match Json.float value with
      | Some encoded -> Stdlib.Ok (Some encoded)
      | None ->
          Stdlib.Error
            (A.Unsupported { provider; feature = "non-finite temperature" }))

let finish_reason = function
  | "stop" -> A.Stop
  | "length" -> A.Length
  | "tool_calls" -> A.Tool_calls
  | "content_filter" -> A.Content_filter
  | "error" -> A.Error
  | other -> A.Other other

let int_member first second json =
  match Json.int_member first json with
  | Some _ as value -> value
  | None -> Json.int_member second json

let usage ?(raw_prompt_names = false) json =
  let input_tokens = int_member "prompt_tokens" "input_tokens" json in
  let output_tokens = int_member "completion_tokens" "output_tokens" json in
  let total_tokens = Json.int_member "total_tokens" json in
  let input_name, output_name =
    if raw_prompt_names then ("prompt_tokens", "completion_tokens")
    else ("input_tokens", "output_tokens")
  in
  {
    A.input_tokens;
    output_tokens;
    total_tokens;
    raw =
      [
        (input_name, Option.value ~default:"" (Option.map string_of_int input_tokens));
        ( output_name,
          Option.value ~default:"" (Option.map string_of_int output_tokens) );
        ("total_tokens", Option.value ~default:"" (Option.map string_of_int total_tokens));
      ];
  }

let raw_json = function
  | `String value -> value
  | json -> Json.compact json


