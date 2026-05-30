(** OpenRouter Responses API ([POST /api/v1/responses]): request builder,
    runner, and streaming variant. This is OpenRouter's only chat-style API. *)

module A = Common.A
module E = Common.E

let request ?structured_output ?routing ?provider:custom_provider ~api_key
    chat_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match Common.encode_responses ?structured_output ?routing chat_request with
  | Stdlib.Ok raw -> Stdlib.Ok (Common.make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let run ?structured_output ?routing ?provider:custom_provider client ~api_key
    chat_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match request ?structured_output ?routing ~provider ~api_key chat_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider chat_request
        (Common.perform_chat provider client http_request)

let stream ?structured_output ?routing ?provider:custom_provider client ~api_key
    chat_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  let chat_request = { chat_request with A.stream = true } in
  match request ?structured_output ?routing ~provider ~api_key chat_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider chat_request
        (Common.perform_stream provider client http_request)
