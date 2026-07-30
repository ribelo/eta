(** OpenAI legacy Chat Completions API ([POST /v1/chat/completions]). Kept for
    callers using the older OpenAI envelope; new code should prefer
    [Responses]. JSON encoding/decoding is delegated to
    [Eta_ai_openai_codec] via [Common]. *)

module A = Common.A
module Codec = Common.Codec
module Json = Common.Json

let inject_structured_output structured_output raw =
  match Json.parse raw with
  | Stdlib.Error message ->
      Stdlib.Error
        (Common.Error.Decode { message; raw_body = Some raw })
  | Stdlib.Ok (`Assoc fields) ->
      let format =
        Codec.structured_output_json ~shape:Codec.Chat_response_format
          structured_output
      in
      let fields =
        List.filter (fun (name, _) -> name <> "response_format") fields
        @ [ ("response_format", format) ]
      in
      Stdlib.Ok (Json.to_string (`Assoc fields))
  | Stdlib.Ok _ ->
      Stdlib.Error
        (Common.Error.Invalid_request
           "Chat Completions encoder did not return a JSON object")

let request ?structured_output ?provider:custom_provider ~api_key chat_request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  (* Always honor the configured encode_chat callback. When structured_output
     is supplied, inject the OpenAI-compatible response_format field into the
     callback's encoded JSON rather than bypassing the callback. *)
  match provider.A.encode_chat chat_request |> Common.of_neutral_result with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw -> (
      match structured_output with
      | None -> Common.raw_chat_request provider ~api_key (Stdlib.Ok raw)
      | Some structured_output -> (
          match inject_structured_output structured_output raw with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok raw ->
              Common.raw_chat_request provider ~api_key (Stdlib.Ok raw)))

let run ?structured_output ?provider:custom_provider client ~api_key
    chat_request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  request ?structured_output ~provider ~api_key chat_request
  |> Common.run_chat provider client chat_request

let stream ?structured_output ?provider:custom_provider client ~api_key
    chat_request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  let chat_request = { chat_request with A.stream = true } in
  request ?structured_output ~provider ~api_key chat_request
  |> Common.run_stream provider client chat_request
