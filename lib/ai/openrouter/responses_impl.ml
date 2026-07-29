(** OpenRouter Responses API ([POST /api/v1/responses]): request builder,
    runner, and streaming variant. This is OpenRouter's only chat-style API. *)

module A = Common.A

let request ?routing ?reasoning ?provider:custom_provider ~api_key
    responses_request =
  let provider =
    Common.default_provider Common.responses_provider custom_provider
  in
  Common.responses_request provider.A.transport ~api_key
    (fun request ->
      match provider.encode_responses request with
      | Stdlib.Error _ as error -> error
      | Stdlib.Ok raw ->
          Common.decorate_responses ?routing ?reasoning request raw)
    responses_request

let run ?routing ?reasoning ?provider:custom_provider client ~api_key
    responses_request =
  let provider =
    Common.default_provider Common.responses_provider custom_provider
  in
  request ?routing ?reasoning ~provider ~api_key
    responses_request
  |> Common.run_responses provider.transport client responses_request

let stream ?routing ?reasoning ?provider:custom_provider client ~api_key
    responses_request =
  let provider =
    Common.default_provider Common.responses_provider custom_provider
  in
  let responses_request =
    { responses_request with A.Responses.stream = true }
  in
  request ?routing ?reasoning ~provider ~api_key
    responses_request
  |> Common.run_responses_stream provider.transport client responses_request
