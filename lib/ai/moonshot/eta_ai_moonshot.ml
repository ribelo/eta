module A = Eta_ai
module Compat = Eta_ai_openai_compat
module Codec = Eta_ai_openai_codec
module H = Eta_http
module Json = A.Json
module E = Eta.Effect

let provider_name = "moonshotai"
let default_base_url = "https://api.moonshot.ai/v1"
let china_base_url = "https://api.moonshot.cn/v1"

type credential = A.api_key

let safe_error message =
  Codec.decode_error_result ~provider:provider_name message

let credential value =
  if String.trim value = "" then safe_error "api_key is empty"
  else Stdlib.Ok (A.api_key (String.trim value))

let api_key key = key

let credential_to_json key =
  Json.object_
    [
      ("type", Some (Json.string "api_key"));
      ("key", Some (Json.string (Eta_redacted.value key)));
    ]

let credential_to_string key = Json.to_string (credential_to_json key)

let credential_of_json = function
  | `Assoc _ as json -> (
      match Json.string_member "type" json with
      | Some "api_key" -> (
          match Json.string_member "key" json with
          | Some key -> credential key
          | None -> safe_error "api_key credential missing key")
      | Some other -> safe_error ("unsupported credential type " ^ other)
      | None -> safe_error "api_key credential missing type")
  | _ -> safe_error "api_key credential must be a JSON object"

let credential_of_string raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_error message
  | Stdlib.Ok json -> credential_of_json json

let pp_credential fmt key = Format.fprintf fmt "%a" Eta_redacted.pp key

let auth_headers ?(extra_headers = []) key =
  H.Core.Header.unsafe_of_list
    ([
       ("Authorization", "Bearer " ^ Eta_redacted.value key);
       ("Content-Type", "application/json");
       ("Accept", "application/json");
     ]
    @ extra_headers)

type structured_output = Codec.structured_output = {
  name : string;
  schema : A.Json.t;
  strict : bool option;
}

let structured_output = Compat.structured_output

let provider ?(base_url = default_base_url) ?(extra_headers = []) () =
  let p =
    Compat.provider ~name:provider_name ~base_url ~chat_path:"/chat/completions"
      ~extra_headers ()
  in
  {
    p with
    auth_headers = (fun key -> auth_headers ~extra_headers key);
    capabilities =
      { p.capabilities with image_input = true; structured_outputs = true };
  }

type supports_thinking_type = Only | No | Both

type think_efforts = {
  support : bool option;
  valid_efforts : string list;
  default_effort : string option;
}

type model_info = {
  id : string;
  display_name : string option;
  context_length : int option;
  supports_reasoning : bool option;
  supports_image_in : bool option;
  supports_video_in : bool option;
  supports_tool_use : bool option;
  supports_thinking_type : supports_thinking_type option;
  think_efforts : think_efforts option;
}

let bool_member name json =
  match Json.member name json with Some (`Bool b) -> Some b | _ -> None

let parse_supports_thinking_type = function
  | Some "only" -> Some Only
  | Some "no" -> Some No
  | Some "both" -> Some Both
  | Some _ | None -> None

let parse_think_efforts = function
  | None -> None
  | Some json ->
      let valid_efforts =
        match Json.array_member "valid_efforts" json with
        | None -> []
        | Some items ->
            List.filter_map (function `String s -> Some s | _ -> None) items
      in
      Some
        {
          support = bool_member "support" json;
          valid_efforts;
          default_effort = Json.string_member "default_effort" json;
        }

let model_info_of_json json =
  match Json.string_member "id" json with
  | None | Some "" -> None
  | Some id ->
      let display_name =
        match Json.string_member "display_name" json with
        | Some _ as v -> v
        | None -> Json.string_member "name" json
      in
      let context_length =
        match Json.int_member "context_length" json with
        | Some _ as v -> v
        | None -> Json.int_member "max_context_length" json
      in
      Some
        {
          id;
          display_name;
          context_length;
          supports_reasoning = bool_member "supports_reasoning" json;
          supports_image_in = bool_member "supports_image_in" json;
          supports_video_in = bool_member "supports_video_in" json;
          supports_tool_use =
            (match Json.member "supports_tool_use" json with
            | None -> Some true
            | Some (`Bool b) -> Some b
            | Some _ -> None);
          supports_thinking_type =
            parse_supports_thinking_type
              (Json.string_member "supports_thinking_type" json);
          think_efforts =
            parse_think_efforts (Json.object_member "think_efforts" json);
        }

let decode_models raw =
  match Json.parse raw with
  | Stdlib.Error message -> safe_error message
  | Stdlib.Ok json ->
      let items =
        match Json.array_member "data" json with
        | Some items -> items
        | None -> ( match json with `List items -> items | _ -> [])
      in
      let models = List.filter_map model_info_of_json items in
      if models = [] then safe_error "models catalog is empty"
      else Stdlib.Ok models

let models_request ?provider:custom ~credential () =
  let provider = match custom with Some p -> p | None -> provider () in
  Stdlib.Ok (A.provider_get_request provider ~path:"/models" credential)

let list_models ?provider:custom client ~credential =
  let provider = match custom with Some p -> p | None -> provider () in
  match models_request ~provider ~credential () with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok request ->
      A.run_raw_decoded provider client (Stdlib.Ok request) decode_models

let encode_chat = Compat.encode_chat
let decode_chat = Compat.decode_chat
let decode_stream_event = Compat.decode_stream_event
let decode_error = Compat.decode_error

let chat_completions_request ?structured_output ?provider:custom ~credential
    request =
  let provider = match custom with Some p -> p | None -> provider () in
  Compat.chat_completions_request ?structured_output ~provider
    ~api_key:credential request

let chat_completions ?structured_output ?provider:custom client ~credential
    request =
  let provider = match custom with Some p -> p | None -> provider () in
  Compat.chat_completions ?structured_output ~provider client
    ~api_key:credential request

let stream_chat_completions ?structured_output ?provider:custom client
    ~credential request =
  let provider = match custom with Some p -> p | None -> provider () in
  Compat.stream_chat_completions ?structured_output ~provider client
    ~api_key:credential request

module Chat = struct
  let request = chat_completions_request
  let run = chat_completions
  let stream = stream_chat_completions
end
