(** xAI Collections management plane and inference-plane document search. *)

type management_key = private string Eta_redacted.t
val management_key : string -> management_key

type field_definition = {
  key : string;
  required : bool option;
  unique : bool option;
  inject_into_chunk : bool option;
  description : string option;
}

type metric_space = Unknown | Cosine | Euclidean | Inner_product

type create_request = {
  collection_name : string;
  team_id : string option;
  collection_description : string option;
  index_configuration : Eta_ai.Json.t option;
  chunk_configuration : Eta_ai.Json.t option;
  metric_space : metric_space option;
  field_definitions : field_definition list;
  version : int option;
}

type field_definition_operation = Add | Delete

type field_definition_update = {
  field_definition : field_definition;
  operation : field_definition_operation;
}

type update_request = {
  team_id : string option;
  collection_name : string option;
  collection_description : string option;
  chunk_configuration : Eta_ai.Json.t option;
  field_definition_updates : field_definition_update list;
}

type resource = {
  collection_id : string;
  collection_name : string option;
  created_at : string option;
  index_configuration : Eta_ai.Json.t option;
  chunk_configuration : Eta_ai.Json.t option;
  metric_space : Eta_ai.Json.t option;
  documents_count : int64 option;
  field_definitions : Eta_ai.Json.t list;
  raw : Eta_ai.raw_json;
}

type list_request = {
  limit : int option;
  order : string option;
  sort_by : string option;
  pagination_token : string option;
  filter : string option;
}

type page = {
  collections : resource list;
  continuation : string option;
  raw : Eta_ai.raw_json;
}

type document = {
  file_metadata : Eta_ai.Json.t option;
  fields : (string * string) list;
  status : string option;
  error_message : string option;
  last_indexed_at : string option;
  raw : Eta_ai.Json.t;
}

type document_page = {
  documents : document list;
  continuation : string option;
  raw : Eta_ai.raw_json;
}

type direct_document = {
  name : string;
  data : bytes;
  content_type : string;
  fields : (string * string) list;
}

val create_collection_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  create_request ->
  (Eta_http.Request.t, Xai_error.t) result

val list_collections_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  list_request ->
  (Eta_http.Request.t, Xai_error.t) result

val get_collection_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  unit ->
  Eta_http.Request.t

val update_collection_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  update_request ->
  Eta_http.Request.t

val delete_collection_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  unit ->
  Eta_http.Request.t

val add_file_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  ?fields:(string * string) list ->
  unit ->
  Eta_http.Request.t

val upload_document_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  direct_document ->
  (Eta_http.Request.t, Xai_error.t) result

val list_documents_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  list_request ->
  (Eta_http.Request.t, Xai_error.t) result

val get_document_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  unit ->
  Eta_http.Request.t

val reindex_document_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  unit ->
  Eta_http.Request.t

val remove_document_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  unit ->
  Eta_http.Request.t

val batch_get_documents_request :
  ?management_endpoint:Endpoint.management ->
  management_key:management_key ->
  collection_id:string ->
  file_ids:string list ->
  unit ->
  (Eta_http.Request.t, Xai_error.t) result

val create_collection :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  create_request ->
  (resource, Xai_error.t) Eta.Effect.t

val list_collections :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  list_request ->
  (page, Xai_error.t) Eta.Effect.t

val get_collection :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  (resource, Xai_error.t) Eta.Effect.t

val update_collection :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  update_request ->
  (resource, Xai_error.t) Eta.Effect.t

val delete_collection :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  (unit, Xai_error.t) Eta.Effect.t

val add_file :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  ?fields:(string * string) list ->
  unit ->
  (unit, Xai_error.t) Eta.Effect.t

val upload_document :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  direct_document ->
  (document, Xai_error.t) Eta.Effect.t

val list_documents :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  list_request ->
  (document_page, Xai_error.t) Eta.Effect.t

val get_document :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  (document, Xai_error.t) Eta.Effect.t

val reindex_document :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  (unit, Xai_error.t) Eta.Effect.t

val remove_document :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  file_id:string ->
  (unit, Xai_error.t) Eta.Effect.t

val batch_get_documents :
  ?management_endpoint:Endpoint.management ->
  Eta_http.Client.t ->
  management_key:management_key ->
  collection_id:string ->
  file_ids:string list ->
  (document list, Xai_error.t) Eta.Effect.t

type retrieval_mode =
  | Semantic of Eta_ai.Json.t option
  | Keyword of Eta_ai.Json.t option
  | Hybrid of Eta_ai.Json.t option

type search_request = {
  query : string;
  collection_ids : string list;
  rag_pipeline : string option;
  filter : string option;
  limit : int option;
  instructions : string option;
  group_by : Eta_ai.Json.t option;
  retrieval_mode : retrieval_mode;
}

type match_ = {
  file_id : string option;
  chunk_id : string option;
  chunk_content : string option;
  score : float option;
  collection_ids : string list;
  fields : (string * Eta_ai.Json.t) list;
  page_number : int option;
  raw : Eta_ai.Json.t;
}

type search_response = {
  matches : match_ list;
  raw : Eta_ai.raw_json;
}

val search_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  search_request ->
  (Eta_http.Request.t, Xai_error.t) result

val search :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  search_request ->
  (search_response, Xai_error.t) Eta.Effect.t
