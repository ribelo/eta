open Types

let option_attr key = function
  | Some value -> [ (key, value) ]
  | None -> []

let option_int_attr key = function
  | Some value -> [ (key, string_of_int value) ]
  | None -> []

let option_float_attr key = function
  | Some value -> [ (key, Printf.sprintf "%.3f" value) ]
  | None -> []

let finish_reason_to_string = function
  | Stop -> "stop"
  | Length -> "length"
  | Tool_calls -> "tool_calls"
  | Content_filter -> "content_filter"
  | Error -> "error"
  | Other value -> value

let finish_reasons_to_string reasons =
  reasons |> List.map finish_reason_to_string |> String.concat ","

let usage_attrs (usage : usage) =
  option_int_attr "gen_ai.usage.input_tokens" usage.input_tokens
  @ option_int_attr "gen_ai.usage.output_tokens" usage.output_tokens

let response_attrs (response : response) =
  option_attr "gen_ai.response.id" response.id
  @ option_attr "gen_ai.response.model" response.model
  @ (match response.finish_reasons with
    | [] -> []
    | reasons ->
        [ ("gen_ai.response.finish_reasons", finish_reasons_to_string reasons) ])
  @
  match response.usage with
  | Some usage -> usage_attrs usage
  | None -> []

let provider_server_attrs (provider : provider) =
  match Eta_http.Core.Url.parse provider.base_url with
  | Stdlib.Ok url ->
      [
        ("server.address", Eta_http.Core.Url.host url);
        ("server.port", string_of_int (Eta_http.Core.Url.effective_port url));
      ]
  | Stdlib.Error _ -> []

let common_attrs ~operation (provider : provider) ~model =
  [
    ("gen_ai.operation.name", operation);
    ("gen_ai.provider.name", provider.name);
    ("gen_ai.request.model", model);
  ]
  @ provider_server_attrs provider

let ai_error_type = function
  | Eta_http_error _ -> "http_error"
  | Provider_error { code = Some code; _ } -> code
  | Provider_error _ -> "provider_error"
  | Decode_error _ -> "decode_error"
  | Invalid_tool _ -> "invalid_tool"
  | Unsupported _ -> "unsupported"

let ai_error_message fmt = function
  | Eta_http_error error ->
      Format.pp_print_string fmt (Eta_http.Error.to_string error)
  | Provider_error { message; _ }
  | Decode_error { message; _ }
  | Invalid_tool { message; _ } ->
      Format.pp_print_string fmt message
  | Unsupported { provider; feature } ->
      Format.fprintf fmt "%s unsupported %s" provider feature

let with_error_type eff =
  eff
  |> Eta.Effect.bind_error (fun error ->
         Eta.Effect.fail error
         |> Eta.Effect.annotate_all [ ("error.type", ai_error_type error) ])

let with_span ~kind ~name ~attrs eff =
  eff |> with_error_type |> Eta.Effect.annotate_all attrs
  |> Eta.Effect.named ~error_pp:ai_error_message ~kind name

let[@inline always] with_response_attrs response_attrs eff =
  eff
  |> Eta.Effect.bind (fun response ->
         Eta.Effect.pure response
         |> Eta.Effect.annotate_all (response_attrs response))

let with_chat_span provider (request : chat_request) eff =
  let eff = with_response_attrs response_attrs eff in
  let attrs =
    common_attrs ~operation:"chat" provider ~model:request.model
    @ if request.stream then [ ("gen_ai.request.stream", "true") ] else []
  in
  with_span ~kind:Eta.Capabilities.Client
    ~name:("chat " ^ request.model)
    ~attrs eff

let with_stream_span ?time_to_first_chunk_s provider (request : chat_request)
    eff =
  let attrs =
    common_attrs ~operation:"chat" provider ~model:request.model
    @ [ ("gen_ai.request.stream", "true") ]
    @ option_float_attr "gen_ai.response.time_to_first_chunk"
        time_to_first_chunk_s
  in
  with_span ~kind:Eta.Capabilities.Client
    ~name:("chat " ^ request.model)
    ~attrs eff

let embedding_usage_attrs (usage : Embedding.usage) =
  option_int_attr "gen_ai.usage.input_tokens" usage.input_tokens
  @ option_int_attr "gen_ai.usage.total_tokens" usage.total_tokens

let embedding_response_attrs (response : Embedding.response) =
  option_attr "gen_ai.response.id" response.id
  @ option_attr "gen_ai.response.model" response.model
  @
  match response.usage with
  | Some usage -> embedding_usage_attrs usage
  | None -> []

let with_embeddings_span provider (request : Embedding.request) eff =
  let eff = with_response_attrs embedding_response_attrs eff in
  let attrs =
    common_attrs ~operation:"embeddings" provider
      ~model:request.model
    @ option_attr "gen_ai.request.encoding_formats" request.encoding_format
  in
  with_span ~kind:Eta.Capabilities.Client
    ~name:("embeddings " ^ request.model)
    ~attrs eff

let with_tool_span ?tool_call_id ?(tool_type = "function") ~tool_name eff =
  let attrs =
    [
      ("gen_ai.operation.name", "execute_tool");
      ("gen_ai.tool.name", tool_name);
      ("gen_ai.tool.type", tool_type);
    ]
    @ option_attr "gen_ai.tool.call.id" tool_call_id
  in
  with_span ~kind:Eta.Capabilities.Internal
    ~name:("execute_tool " ^ tool_name)
    ~attrs eff

let suppress_provider_transport_observability =
  Eta.Effect.suppress_observability

