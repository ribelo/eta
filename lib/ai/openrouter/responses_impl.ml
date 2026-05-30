(** OpenRouter Responses API ([POST /api/v1/responses]): request builder,
    runner, and streaming variant. This is OpenRouter's only chat-style API. *)

module A = Common.A

let request ?structured_output ?routing ?provider:custom_provider ~api_key
    chat_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.chat_request provider ~api_key
    (Common.encode_responses ?structured_output ?routing)
    chat_request

let run ?structured_output ?routing ?provider:custom_provider client ~api_key
    chat_request =
  let provider = Common.default_provider Common.provider custom_provider in
  request ?structured_output ?routing ~provider ~api_key chat_request
  |> Common.run_chat provider client chat_request

let stream ?structured_output ?routing ?provider:custom_provider client ~api_key
    chat_request =
  let provider = Common.default_provider Common.provider custom_provider in
  let chat_request = { chat_request with A.stream = true } in
  request ?structured_output ?routing ~provider ~api_key chat_request
  |> Common.run_stream provider client chat_request
