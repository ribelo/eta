(** OpenAI Embeddings API ([POST /v1/embeddings]). *)

module A = Common.A
module E = Common.E

let request ?provider:custom_provider ~api_key embedding_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  A.embeddings_request provider ~api_key embedding_request

let run ?provider:custom_provider client ~api_key embedding_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match request ~provider ~api_key embedding_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.with_embeddings_span provider embedding_request
        (Common.perform_embeddings provider client http_request)
