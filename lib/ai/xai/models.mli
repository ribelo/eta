(** xAI inference model catalogs. *)

type model = {
  id : string;
  aliases : string list;
  created : int64 option;
  object_ : string option;
  owned_by : string option;
  context_length : int64 option;
  prompt_text_token_price : int64 option;
  cached_prompt_text_token_price : int64 option;
  prompt_image_token_price : int64 option;
  completion_text_token_price : int64 option;
  long_context_threshold : int64 option;
  image_price : int64 option;
  raw : Eta_ai.Json.t;
}

type language_model = {
  id : string;
  fingerprint : string option;
  version : string option;
  input_modalities : string list;
  output_modalities : string list;
  search_price : int64 option;
  aliases : string list;
  raw : Eta_ai.Json.t;
}

type catalog_model = {
  id : string;
  aliases : string list;
  raw : Eta_ai.Json.t;
}

val models_request :
  ?endpoint:Endpoint.inference -> api_key:Eta_ai.api_key -> unit -> Eta_http.Request.t
val model_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  unit ->
  Eta_http.Request.t
val language_models_request :
  ?endpoint:Endpoint.inference -> api_key:Eta_ai.api_key -> unit -> Eta_http.Request.t
val language_model_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  unit ->
  Eta_http.Request.t
val embedding_models_request :
  ?endpoint:Endpoint.inference -> api_key:Eta_ai.api_key -> unit -> Eta_http.Request.t
val embedding_model_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  unit ->
  Eta_http.Request.t
val image_generation_models_request :
  ?endpoint:Endpoint.inference -> api_key:Eta_ai.api_key -> unit -> Eta_http.Request.t
val image_generation_model_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  unit ->
  Eta_http.Request.t
val video_generation_models_request :
  ?endpoint:Endpoint.inference -> api_key:Eta_ai.api_key -> unit -> Eta_http.Request.t
val video_generation_model_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  unit ->
  Eta_http.Request.t

val list_models :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (model list, Xai_error.t) Eta.Effect.t
val get_model :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  (model, Xai_error.t) Eta.Effect.t
val list_language_models :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (language_model list, Xai_error.t) Eta.Effect.t
val get_language_model :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  (language_model, Xai_error.t) Eta.Effect.t
val list_embedding_models :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (catalog_model list, Xai_error.t) Eta.Effect.t
val get_embedding_model :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  (catalog_model, Xai_error.t) Eta.Effect.t
val list_image_generation_models :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (catalog_model list, Xai_error.t) Eta.Effect.t
val get_image_generation_model :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  (catalog_model, Xai_error.t) Eta.Effect.t
val list_video_generation_models :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (catalog_model list, Xai_error.t) Eta.Effect.t
val get_video_generation_model :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  model_id:string ->
  (catalog_model, Xai_error.t) Eta.Effect.t
