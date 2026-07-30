(** OpenAI Responses API ([POST /v1/responses]): request builder, runner, and
    streaming variant. The Responses API is the modern OpenAI chat surface and
    the only chat-style API exposed by OpenRouter. JSON encoding/decoding is
    delegated to [Eta_ai_openai_codec] via [Common]. *)

module A = Common.A

let request ?provider:custom_provider ~api_key responses_request =
  let provider =
    Common.default_provider Common.responses_provider custom_provider
  in
  let encoded =
    match provider.encode_responses responses_request with
    | Stdlib.Ok _ as ok -> ok
    | Stdlib.Error error -> Stdlib.Error (Common.Error.of_ai_error error)
  in
  Common.raw_chat_request provider.A.transport ~api_key encoded

let run ?provider:custom_provider client ~api_key responses_request =
  let provider =
    Common.default_provider Common.responses_provider custom_provider
  in
  request ~provider ~api_key responses_request
  |> Common.run_responses provider client responses_request

let stream ?provider:custom_provider client ~api_key responses_request =
  let provider =
    Common.default_provider Common.responses_provider custom_provider
  in
  let responses_request =
    { responses_request with A.Responses.stream = true }
  in
  request ~provider ~api_key responses_request
  |> Common.run_responses_stream provider client responses_request
