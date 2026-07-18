module A = Eta_ai
module Json = A.Json

let ( let* ) = Result.bind

type structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let structured_output ~schema_value ?strict ~name ~schema_json () =
  let trimmed = A.Json_helpers.trim name in
  if String.equal trimmed "" then
    Stdlib.Error
      (A.Invalid_tool { name; message = "structured output name is required" })
  else
    let* schema = schema_value "structured output schema_json" schema_json in
    Stdlib.Ok { name = trimmed; schema; strict }

let decode_error_result = A.Json_helpers.decode_error_result
let parse_json = A.Json_helpers.parse_json
let schema_value = A.Json_helpers.schema_value

let result_all = A.Json_helpers.result_all
let result_map_all = A.Json_helpers.result_map_all

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
  | Some value when A.Json_helpers.is_blank value ->
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
  let nested_int object_name field_name =
    Option.bind (Json.object_member object_name json) (Json.int_member field_name)
  in
  let input_details_name, output_details_name =
    if raw_prompt_names then
      ("prompt_tokens_details", "completion_tokens_details")
    else ("input_tokens_details", "output_tokens_details")
  in
  let cache_read_tokens =
    nested_int input_details_name "cached_tokens"
  in
  let cache_write_tokens =
    nested_int input_details_name "cache_write_tokens"
  in
  let reasoning_tokens =
    nested_int output_details_name "reasoning_tokens"
  in
  let input_name, output_name =
    if raw_prompt_names then ("prompt_tokens", "completion_tokens")
    else ("input_tokens", "output_tokens")
  in
  let nested_scalar object_name field_name =
    Option.bind (Json.object_member object_name json)
      (Json.scalar_string_member field_name)
  in
  let nested_scalar_first object_name names =
    let rec loop = function
      | [] -> None
      | name :: rest -> (
          match nested_scalar object_name name with
          | Some _ as value -> value
          | None -> loop rest)
    in
    loop names
  in
  let optional_raw name = function None -> [] | Some value -> [ (name, value) ] in
  let subtract left rights =
    Option.map
      (fun total ->
        Int.max 0
          (List.fold_left
             (fun total value -> total - Option.value ~default:0 value)
             total rights))
      left
  in
  {
    A.input_tokens =
      {
        uncached =
          subtract input_tokens [ cache_read_tokens; cache_write_tokens ];
        total = input_tokens;
        cache_read = cache_read_tokens;
        cache_write = cache_write_tokens;
      };
    output_tokens =
      {
        total = output_tokens;
        text = subtract output_tokens [ reasoning_tokens ];
        reasoning = reasoning_tokens;
      };
    raw =
      [
        (input_name, Option.value ~default:"" (Option.map string_of_int input_tokens));
        ( output_name,
          Option.value ~default:"" (Option.map string_of_int output_tokens) );
        ("total_tokens", Option.value ~default:"" (Option.map string_of_int total_tokens));
      ]
      @ optional_raw "cached_tokens"
          (nested_scalar input_details_name "cached_tokens")
      @ optional_raw "cache_write_tokens"
          (nested_scalar input_details_name "cache_write_tokens")
      @ optional_raw "reasoning_tokens"
          (nested_scalar output_details_name "reasoning_tokens")
      @ optional_raw "cost" (Json.scalar_string_member "cost" json)
      @ optional_raw "prompt_cost"
          (nested_scalar "cost_details" "upstream_inference_prompt_cost")
      @ optional_raw "input_cost"
          (nested_scalar "cost_details" "upstream_inference_input_cost")
      @ optional_raw "output_cost"
          (nested_scalar_first "cost_details"
             [
               "upstream_inference_completions_cost";
               "upstream_inference_output_cost";
             ]);
  }

let raw_json = function
  | `String value -> value
  | json -> Json.compact json

let with_json_fields extra fields =
  match extra with
  | [] -> Json.object_ fields
  | _ ->
      Json.object_
        (fields @ List.map (fun (name, value) -> (name, Some value)) extra)

let encode_speech ?(instructions = true) ~provider
    (request : A.Speech.request) =
  if A.Json_helpers.is_blank request.input then
    unsupported ~provider "speech input must not be empty"
  else if A.Json_helpers.is_blank request.voice then
    unsupported ~provider "speech voice must not be empty"
  else if (not instructions) && Option.is_some request.instructions then
    unsupported ~provider "speech instructions"
  else
    let speed =
      match request.speed with
      | None -> Stdlib.Ok None
      | Some value -> (
          match Json.float value with
          | Some json -> Stdlib.Ok (Some json)
          | None -> unsupported ~provider "speech speed must be finite")
    in
    let* speed = speed in
    Stdlib.Ok
      (with_json_fields request.extra
         [
           ("model", Some (Json.string request.model));
           ("input", Some (Json.string request.input));
           ("voice", Some (Json.string request.voice));
           ("response_format", Option.map Json.string request.response_format);
           ("speed", speed);
           ( "instructions",
             if instructions then Option.map Json.string request.instructions
             else None );
         ]
      |> Json.to_string)
