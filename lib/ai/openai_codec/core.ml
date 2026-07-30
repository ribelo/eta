module A = Eta_ai
module Json = A.Json

let ( let* ) = Result.bind

type structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

type codec_failure =
  | Invalid_request of string
  | Unsupported of string
  | Invalid_tool of {
      name : string;
      message : string;
    }
  | Decode of {
      message : string;
      raw_body : A.raw_json option;
    }

let ai_error_of_codec_failure ~provider = function
  | Invalid_request message ->
      (* Built-in structured projection uses explicit Invalid_request. *)
      A.Invalid_request { provider; message }
  | Unsupported message -> A.Unsupported { provider; feature = message }
  | Invalid_tool { name; message } -> A.Invalid_tool { name; message }
  | Decode { message; raw_body } ->
      A.Decode_error { provider; message; raw = raw_body }

(* Historical unmigrated wrappers: local validation remains Unsupported. *)
let ai_error_of_codec_failure_historical ~provider = function
  | Invalid_request message | Unsupported message ->
      A.Unsupported { provider; feature = message }
  | Invalid_tool { name; message } -> A.Invalid_tool { name; message }
  | Decode { message; raw_body } ->
      A.Decode_error { provider; message; raw = raw_body }

let map_codec_failure ~provider = function
  | Stdlib.Ok _ as ok -> ok
  | Stdlib.Error failure ->
      Stdlib.Error (ai_error_of_codec_failure_historical ~provider failure)

let structured_output_lossless ~schema_value ?strict ~name ~schema_json () =
  let trimmed = A.Json_helpers.trim name in
  if String.equal trimmed "" then
    Stdlib.Error
      (Invalid_tool { name; message = "structured output name is required" })
  else (
    match schema_value "structured output schema_json" schema_json with
    | Stdlib.Error (Decode _ as failure) -> Stdlib.Error failure
    | Stdlib.Error failure -> Stdlib.Error failure
    | Stdlib.Ok schema -> Stdlib.Ok { name = trimmed; schema; strict })

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

(* Historical neutral unavailable-feature channel. *)
let unsupported ~provider feature =
  Stdlib.Error (A.Unsupported { provider; feature })

type reasoning_level = Off | Minimal | Low | Medium | High | Xhigh | Max

let reasoning_level_of_string_lossless = function
  | value when A.Json_helpers.is_blank value ->
      Stdlib.Error (Invalid_request "reasoning level must not be empty")
  | "off" -> Stdlib.Ok Off
  | "minimal" -> Stdlib.Ok Minimal
  | "low" -> Stdlib.Ok Low
  | "medium" -> Stdlib.Ok Medium
  | "high" -> Stdlib.Ok High
  | "xhigh" -> Stdlib.Ok Xhigh
  | "max" -> Stdlib.Ok Max
  | _ ->
      Stdlib.Error
        (Invalid_request
           "reasoning level must be off, minimal, low, medium, high, xhigh, or max")

let reasoning_level_of_string ~provider value =
  reasoning_level_of_string_lossless value |> map_codec_failure ~provider

let reasoning_level_to_string = function
  | Off -> "off"
  | Minimal -> "minimal"
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Xhigh -> "xhigh"
  | Max -> "max"

let non_empty_list_lossless label = function
  | [] -> Stdlib.Error (Invalid_request (label ^ " must not be empty"))
  | values -> Stdlib.Ok values

let non_empty_list ~provider label values =
  non_empty_list_lossless label values |> map_codec_failure ~provider

let positive_int_json_lossless label = function
  | None -> Stdlib.Ok None
  | Some value when value > 0 -> Stdlib.Ok (Some (Json.int value))
  | Some _ -> Stdlib.Error (Invalid_request (label ^ " must be positive"))

let positive_int_json ~provider label value =
  positive_int_json_lossless label value |> map_codec_failure ~provider

let optional_non_empty_lossless label = function
  | None -> Stdlib.Ok None
  | Some value when A.Json_helpers.is_blank value ->
      Stdlib.Error (Invalid_request (label ^ " must not be empty"))
  | Some value -> Stdlib.Ok (Some value)

let optional_non_empty ~provider label value =
  optional_non_empty_lossless label value |> map_codec_failure ~provider

let embedding_encoding_format_json_lossless = function
  | None -> Stdlib.Ok None
  | Some ("float" | "base64" as value) -> Stdlib.Ok (Some (Json.string value))
  | Some _ ->
      Stdlib.Error
        (Invalid_request "embedding encoding_format must be float or base64")

let embedding_encoding_format_json ~provider value =
  embedding_encoding_format_json_lossless value |> map_codec_failure ~provider

let temperature_json_lossless = function
  | None -> Stdlib.Ok None
  | Some value -> (
      match Json.float value with
      | Some encoded -> Stdlib.Ok (Some encoded)
      | None -> Stdlib.Error (Invalid_request "non-finite temperature"))

let temperature_json ~provider value =
  temperature_json_lossless value |> map_codec_failure ~provider

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
    match nested_int input_details_name "cached_tokens" with
    | Some _ as value -> value
    | None -> Json.int_member "cached_tokens" json
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
  let cache_read_raw =
    match nested_scalar input_details_name "cached_tokens" with
    | Some _ as value -> value
    | None -> Json.scalar_string_member "cached_tokens" json
  in
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
      @ optional_raw "cached_tokens" cache_read_raw
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

let encode_speech_lossless ?(instructions = true) ~model ~input ~voice
    ?response_format ?speed ?speech_instructions ?(extra = []) () =
  if A.Json_helpers.is_blank input then
    Stdlib.Error (Invalid_request "speech input must not be empty")
  else if A.Json_helpers.is_blank voice then
    Stdlib.Error (Invalid_request "speech voice must not be empty")
  else if (not instructions) && Option.is_some speech_instructions then
    Stdlib.Error (Unsupported "speech instructions")
  else
    let speed =
      match speed with
      | None -> Stdlib.Ok None
      | Some value -> (
          match Json.float value with
          | Some json -> Stdlib.Ok (Some json)
          | None -> Stdlib.Error (Invalid_request "speech speed must be finite"))
    in
    match speed with
    | Stdlib.Error _ as error -> error
    | Stdlib.Ok speed ->
        Stdlib.Ok
          (with_json_fields extra
             [
               ("model", Some (Json.string model));
               ("input", Some (Json.string input));
               ("voice", Some (Json.string voice));
               ( "response_format",
                 Option.map Json.string response_format );
               ("speed", speed);
               ( "instructions",
                 if instructions then Option.map Json.string speech_instructions
                 else None );
             ]
          |> Json.to_string)

let encode_speech ?(instructions = true) ~provider ~model ~input ~voice
    ?response_format ?speed ?speech_instructions ?extra () =
  encode_speech_lossless ~instructions ~model ~input ~voice ?response_format
    ?speed ?speech_instructions ?extra ()
  |> map_codec_failure ~provider
