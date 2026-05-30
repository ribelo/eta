(** OpenAI legacy Chat Completions API ([POST /v1/chat/completions]). Kept for
    callers using the older OpenAI envelope; new code should prefer
    [Responses]. JSON encoding/decoding is delegated to
    [Eta_ai_openai_codec] via [Common]. *)

module A = Common.A
module E = Common.E

let request ?structured_output ?provider:custom_provider ~api_key chat_request =
  let provider =
    Option.value ~default:(Common.chat_completions_provider ()) custom_provider
  in
  let encoded =
    match structured_output with
    | None -> provider.A.encode_chat chat_request
    | Some _ -> Common.encode_chat ?structured_output chat_request
  in
  match encoded with
  | Stdlib.Ok raw -> Stdlib.Ok (Common.make_request provider api_key raw)
  | Stdlib.Error _ as error -> error

let run ?structured_output ?provider:custom_provider client ~api_key
    chat_request =
  let provider =
    Option.value ~default:(Common.chat_completions_provider ()) custom_provider
  in
  match request ?structured_output ~provider ~api_key chat_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_chat_span provider chat_request
        (Common.perform_chat provider client http_request)

let stream ?structured_output ?provider:custom_provider client ~api_key
    chat_request =
  let provider =
    Option.value ~default:(Common.chat_completions_provider ()) custom_provider
  in
  let chat_request = { chat_request with A.stream = true } in
  match request ?structured_output ~provider ~api_key chat_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_stream_span provider chat_request
        (Common.perform_stream provider client http_request)
