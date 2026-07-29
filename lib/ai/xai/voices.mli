(** Built-in and read-only custom voice discovery. *)

type built_in = {
  voice_id : string;
  name : string option;
  language : string option;
  raw : Eta_ai.Json.t;
}

type custom = {
  voice_id : string;
  name : string option;
  description : string option;
  language : string option;
  created_at : string option;
  raw : Eta_ai.Json.t;
}

type custom_page = {
  voices : custom list;
  continuation : string option;
  raw : Eta_ai.raw_json;
}

type audio = {
  content_type : string option;
  bytes : bytes;
}

val built_in_list_request :
  ?endpoint:Endpoint.inference -> api_key:Eta_ai.api_key -> unit -> Eta_http.Request.t
val built_in_get_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  voice_id:string ->
  unit ->
  Eta_http.Request.t
val custom_list_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  ?limit:int ->
  ?pagination_token:string ->
  unit ->
  (Eta_http.Request.t, Xai_error.t) result
val custom_get_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  voice_id:string ->
  unit ->
  Eta_http.Request.t
val custom_audio_request :
  ?endpoint:Endpoint.inference ->
  api_key:Eta_ai.api_key ->
  voice_id:string ->
  unit ->
  Eta_http.Request.t

val list_built_in :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (built_in list, Xai_error.t) Eta.Effect.t
val get_built_in :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  voice_id:string ->
  (built_in, Xai_error.t) Eta.Effect.t
val list_custom :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  ?limit:int ->
  ?pagination_token:string ->
  unit ->
  (custom_page, Xai_error.t) Eta.Effect.t
val get_custom :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  voice_id:string ->
  (custom, Xai_error.t) Eta.Effect.t
val custom_audio :
  ?endpoint:Endpoint.inference ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  voice_id:string ->
  (audio, Xai_error.t) Eta.Effect.t
