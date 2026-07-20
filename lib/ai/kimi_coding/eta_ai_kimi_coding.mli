(** Kimi Coding provider facade.

    Chat defaults to Kimi-native Chat Completions at
    [https://api.kimi.com/coding/v1/chat/completions]. When catalog metadata
    declares [protocol = "anthropic"], use {!messages_provider} /
    {!messages_request} for Anthropic-compatible Messages with the same Kimi
    credentials and identity headers. Device-code OAuth targets
    [https://auth.kimi.com]. *)

val provider_name : string
val default_base_url : string
val default_oauth_host : string
val client_id : string
val default_platform : string

(** {1 Credentials} *)

type api_key_credential = Eta_ai.api_key

type oauth_credential = {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_at : int64 option;
  scope : string option;
  token_type : string option;
}

type credential = Api_key of api_key_credential | OAuth of oauth_credential

val api_key : string -> api_key_credential

val oauth_credential :
  access_token:string ->
  refresh_token:string ->
  ?expires_at:int64 ->
  ?scope:string ->
  ?token_type:string ->
  unit ->
  oauth_credential

val credential_to_json : credential -> Eta_ai.Json.t
val credential_of_json : Eta_ai.Json.t -> (credential, Eta_ai.ai_error) result
val credential_to_string : credential -> Eta_ai.raw_json

val credential_of_string :
  Eta_ai.raw_json -> (credential, Eta_ai.ai_error) result

val pp_credential : Format.formatter -> credential -> unit
val access_api_key : credential -> Eta_ai.api_key

(** {1 Provider-owned headers} *)

type device_identity = {
  platform : string;
  version : string;
  device_name : string option;
  device_model : string option;
  os_version : string option;
  device_id : string option;
}

val device_identity :
  ?platform:string ->
  version:string ->
  ?device_name:string ->
  ?device_model:string ->
  ?os_version:string ->
  ?device_id:string ->
  unit ->
  device_identity

val auth_headers :
  ?identity:device_identity ->
  ?extra_headers:Eta_ai.headers ->
  credential ->
  Eta_ai.headers

(** {1 Device-code OAuth} *)

type device_authorization = {
  user_code : string;
  device_code : string;
  verification_uri : string;
  verification_uri_complete : string option;
  expires_in : int option;
  interval : int;
}

type device_poll_result =
  | Authorized of oauth_credential
  | Pending of { error_code : string; description : string option }
  | Slow_down of { description : string option }
  | Expired of { description : string option }
  | Denied of { description : string option }

val device_authorization_request :
  ?oauth_host:string ->
  ?client_id:string ->
  ?identity:device_identity ->
  unit ->
  Eta_http.Request.t

val decode_device_authorization :
  Eta_ai.raw_json -> (device_authorization, Eta_ai.ai_error) result

val request_device_authorization :
  ?oauth_host:string ->
  ?client_id:string ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  (device_authorization, Eta_ai.ai_error) Eta.Effect.t

val device_token_poll_request :
  ?oauth_host:string ->
  ?client_id:string ->
  ?identity:device_identity ->
  device_code:string ->
  unit ->
  Eta_http.Request.t

val decode_device_poll :
  status:int -> Eta_ai.raw_json -> (device_poll_result, Eta_ai.ai_error) result

val poll_device_token :
  ?oauth_host:string ->
  ?client_id:string ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  device_code:string ->
  (device_poll_result, Eta_ai.ai_error) Eta.Effect.t

val refresh_request :
  ?oauth_host:string ->
  ?client_id:string ->
  ?identity:device_identity ->
  refresh_token:string ->
  unit ->
  Eta_http.Request.t

val decode_token_response :
  Eta_ai.raw_json -> (oauth_credential, Eta_ai.ai_error) result

val refresh :
  ?oauth_host:string ->
  ?client_id:string ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  refresh_token:string ->
  (oauth_credential, Eta_ai.ai_error) Eta.Effect.t

(** {1 Native catalog} *)

type protocol = Kimi | Anthropic

val protocol_to_string : protocol -> string
val protocol_of_string : string -> protocol option

type model_info = {
  id : string;
  display_name : string option;
  context_length : int option;
  supports_reasoning : bool option;
  supports_image_in : bool option;
  supports_video_in : bool option;
  supports_tool_use : bool option;
  protocol : protocol option;
  raw : Eta_ai.Json.t option;
}

val models_request :
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  credential:credential ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val decode_models : Eta_ai.raw_json -> (model_info list, Eta_ai.ai_error) result

val list_models :
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  credential:credential ->
  (model_info list, Eta_ai.ai_error) Eta.Effect.t

(** {1 Chat Completions} *)

type structured_output = Eta_ai_openai_codec.structured_output = {
  name : string;
  schema : Eta_ai.Json.t;
  strict : bool option;
}

val structured_output :
  ?strict:bool ->
  name:string ->
  schema_json:Eta_ai.raw_json ->
  unit ->
  (structured_output, Eta_ai.ai_error) result

val provider :
  ?base_url:string ->
  ?identity:device_identity ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.provider

val encode_chat :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_chat : Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result

val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result

val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

val chat_completions_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_chat_completions :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

(** {1 Anthropic-compatible Messages}

    For catalog models with [protocol = anthropic]. Reuses [Eta_ai_anthropic]
    codecs against the Kimi Coding base URL and attaches Kimi provider-owned
    Bearer + [X-Msh-*] headers. Path defaults to [/messages?beta=true]. *)

val default_messages_path : string

val messages_provider :
  ?base_url:string ->
  ?identity:device_identity ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.provider

val encode_messages :
  Eta_ai.chat_request -> (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_message :
  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result

val decode_messages_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result

val messages_request :
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val messages :
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_messages :
  ?provider:Eta_ai.provider ->
  ?identity:device_identity ->
  Eta_http.Client.t ->
  credential:credential ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

module Messages : sig
  val request :
    ?provider:Eta_ai.provider ->
    ?identity:device_identity ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run :
    ?provider:Eta_ai.provider ->
    ?identity:device_identity ->
    Eta_http.Client.t ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream :
    ?provider:Eta_ai.provider ->
    ?identity:device_identity ->
    Eta_http.Client.t ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end

module Chat : sig
  val request :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    ?identity:device_identity ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    ?identity:device_identity ->
    Eta_http.Client.t ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    ?identity:device_identity ->
    Eta_http.Client.t ->
    credential:credential ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end
