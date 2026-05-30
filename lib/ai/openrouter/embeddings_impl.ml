(** OpenRouter Embeddings API ([POST /api/v1/embeddings]). Adds [routing] and
    [input_type] knobs on top of the OpenAI-style envelope. *)

module A = Common.A

let request ?routing ?input_type ?provider:custom_provider ~api_key
    embedding_request =
  let provider = Common.default_provider Common.provider custom_provider in
  Common.embeddings_request provider ~api_key
    (Common.encode_embeddings ?routing ?input_type)
    embedding_request

let run ?routing ?input_type ?provider:custom_provider client ~api_key
    embedding_request =
  let provider = Common.default_provider Common.provider custom_provider in
  request ?routing ?input_type ~provider ~api_key embedding_request
  |> Common.run_embeddings provider client embedding_request
