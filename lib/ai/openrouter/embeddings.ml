(** OpenRouter Embeddings API ([POST /api/v1/embeddings]). Adds [routing] and
    [input_type] knobs on top of the OpenAI-style envelope. *)

module A = Common.A
module E = Common.E

let request ?routing ?input_type ?provider:custom_provider ~api_key
    embedding_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match Common.encode_embeddings ?routing ?input_type embedding_request with
  | Stdlib.Ok raw -> A.provider_embeddings_request provider api_key raw
  | Stdlib.Error _ as error -> error

let run ?routing ?input_type ?provider:custom_provider client ~api_key
    embedding_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match
    request ?routing ?input_type ~provider ~api_key embedding_request
  with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_embeddings_span provider embedding_request
        (Common.perform_embeddings provider client http_request)
