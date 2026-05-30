(** OpenAI Embeddings API ([POST /v1/embeddings]). *)

module A = Common.A

let request ?provider:custom_provider ~api_key embedding_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.embeddings_request provider ~api_key embedding_request

let run ?provider:custom_provider client ~api_key embedding_request =
  let provider = Common.default_provider Common.provider custom_provider in
  request ~provider ~api_key embedding_request
  |> Common.run_embeddings provider client embedding_request
