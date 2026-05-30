(** OpenAI legacy Chat Completions API ([POST /v1/chat/completions]). Kept for
    callers using the older OpenAI envelope; new code should prefer
    [Responses]. JSON encoding/decoding is delegated to
    [Eta_ai_openai_codec] via [Common]. *)

module A = Common.A

let request ?structured_output ?provider:custom_provider ~api_key chat_request =
  let provider =
    Common.default_provider Common.chat_completions_provider custom_provider
  in
  let encoded =
    match structured_output with
    | None -> provider.A.encode_chat chat_request
    | Some _ -> Common.encode_chat ?structured_output chat_request
  in
  Common.raw_chat_request provider ~api_key encoded

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
