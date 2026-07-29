(** Stable inference-side Files API operations. *)

type resource = {
  id : string;
  object_ : string option;
  bytes : int64 option;
  created_at : int64 option;
  expires_at : int64 option;
  filename : string option;
  purpose : string option;
  public_url : string option;
  public_url_expires_at : int64 option;
  raw : Eta_ai.raw_json;
}

type order = Asc | Desc
type sort_by = Created_at | Filename | Size

type list_request = {
  limit : int option;
  order : order option;
  sort_by : sort_by option;
  pagination_token : string option;
  filter : string option;
}

type page = {
  data : resource list;
  continuation : string option;
  raw : Eta_ai.raw_json;
}

type deleted = {
  id : string;
  object_ : string option;
  deleted : bool;
  raw : Eta_ai.raw_json;
}

type content_format = Original | Text

type content = {
  content_type : string option;
  bytes : bytes;
}

type public_url = {
  public_url : string;
  expires_at : int64 option;
  raw : Eta_ai.raw_json;
}

type revocation = {
  id : string option;
  revoked : bool;
  public_url : string option;
  raw : Eta_ai.raw_json;
}

val upload_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  ?expires_after_s:int ->
  ?purpose:string ->
  Eta_ai.binary_file ->
  (Eta_http.Request.t, Xai_error.t) result

val list_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  list_request ->
  (Eta_http.Request.t, Xai_error.t) result

val get_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  unit ->
  Eta_http.Request.t

val delete_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  unit ->
  Eta_http.Request.t

val content_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  format:content_format ->
  unit ->
  Eta_http.Request.t

val create_public_url_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  ?expires_after_s:int ->
  unit ->
  (Eta_http.Request.t, Xai_error.t) result

val revoke_public_url_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  unit ->
  Eta_http.Request.t

val upload :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  ?expires_after_s:int ->
  ?purpose:string ->
  Eta_ai.binary_file ->
  (resource, Xai_error.t) Eta.Effect.t

val list :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  list_request ->
  (page, Xai_error.t) Eta.Effect.t

val get :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  (resource, Xai_error.t) Eta.Effect.t

val delete :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  (deleted, Xai_error.t) Eta.Effect.t

val content :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  format:content_format ->
  (content, Xai_error.t) Eta.Effect.t

val create_public_url :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  ?expires_after_s:int ->
  unit ->
  (public_url, Xai_error.t) Eta.Effect.t

val revoke_public_url :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  file_id:string ->
  (revocation, Xai_error.t) Eta.Effect.t
