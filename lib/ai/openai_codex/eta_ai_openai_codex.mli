(** OpenAI Codex (ChatGPT subscription) Responses provider.

    Wire defaults follow the Codex CLI: Responses at
    [https://chatgpt.com/backend-api/codex/responses] with ChatGPT OAuth PKCE
    against [https://auth.openai.com]. Callers own credential storage,
    selection, and cryptographically secure entropy. This package owns
    credential types/codecs, OAuth planning/parsing, provider headers, and
    request builders. *)

val provider_name : string
val default_base_url : string
val default_issuer : string
val default_redirect_uri : string
val client_id : string
val default_originator : string

(** {1 Subscription OAuth credentials} *)

type oauth_credential = private {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_at_ms : int64 option;
  account_id : string;
}
(** Durable ChatGPT OAuth credential. [account_id] is required for Codex wire
    headers. Secrets are redacted. *)

val oauth_credential :
  access_token:string ->
  refresh_token:string ->
  ?expires_at_ms:int64 ->
  account_id:string ->
  unit ->
  (oauth_credential, Eta_ai.ai_error) result

val credential_to_json : oauth_credential -> Eta_ai.Json.t

val credential_of_json :
  Eta_ai.Json.t -> (oauth_credential, Eta_ai.ai_error) result

val credential_to_string : oauth_credential -> Eta_ai.raw_json

val credential_of_string :
  Eta_ai.raw_json -> (oauth_credential, Eta_ai.ai_error) result

val pp_credential : Format.formatter -> oauth_credential -> unit
(** Prints a diagnostic that never includes secret token values. *)

val access_api_key : oauth_credential -> Eta_ai.api_key

(** {1 PKCE authorization} *)

type pkce = {
  code_verifier : string;
  code_challenge : string;
  code_challenge_method : string;
}

val pkce_s256 : code_verifier:string -> (pkce, Eta_ai.ai_error) result
(** RFC 7636 S256 challenge from a caller-supplied verifier. *)

val code_verifier_of_entropy : string -> (string, Eta_ai.ai_error) result
(** Encode caller-supplied CSPRNG bytes as a URL-safe verifier. Requires at
    least 32 entropy bytes. *)

val state_of_entropy : string -> (string, Eta_ai.ai_error) result
(** Encode caller-supplied CSPRNG bytes as OAuth [state]. Requires at least 16
    entropy bytes. *)

type authorize_plan = {
  authorize_url : string;
  redirect_uri : string;
  state : string;
  pkce : pkce;
  client_id : string;
  issuer : string;
}

val plan_authorize :
  ?issuer:string ->
  ?client_id:string ->
  ?redirect_uri:string ->
  ?originator:string ->
  state:string ->
  code_verifier:string ->
  unit ->
  (authorize_plan, Eta_ai.ai_error) result
(** Plan a browser PKCE authorize URL. Entropy must be supplied by the caller
    via [state] and [code_verifier]. *)

type callback_input =
  | Callback_url of string
  | Callback_query of string
  | Callback_code of { code : string; state : string option }

type authorization_code = { code : string; state : string }

val parse_authorization_callback :
  expected_state:string ->
  callback_input ->
  (authorization_code, Eta_ai.ai_error) result
(** Parse a browser callback URL/query/code and validate OAuth [state]. *)

(** {1 Token exchange and refresh} *)

type token_set = private {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_in : int;
  id_token : string Eta_redacted.t option;
  account_id : string;
}

val credential_of_token_set : now_ms:int64 -> token_set -> oauth_credential

val exchange_code_request :
  ?issuer:string ->
  ?client_id:string ->
  redirect_uri:string ->
  code:string ->
  code_verifier:string ->
  unit ->
  Eta_http.Request.t

val refresh_request :
  ?issuer:string -> ?client_id:string -> oauth_credential -> Eta_http.Request.t

val decode_token_response :
  Eta_ai.raw_json -> (token_set, Eta_ai.ai_error) result

val exchange_code :
  ?issuer:string ->
  ?client_id:string ->
  Eta_http.Client.t ->
  redirect_uri:string ->
  code:string ->
  code_verifier:string ->
  now_ms:int64 ->
  (oauth_credential, Eta_ai.ai_error) Eta.Effect.t
(** Deep exchange: returns a durable credential with required account identity
    and absolute expiry. OAuth HTTP failures are typed provider errors with safe
    code/description only. *)

val refresh :
  ?issuer:string ->
  ?client_id:string ->
  Eta_http.Client.t ->
  oauth_credential ->
  now_ms:int64 ->
  (oauth_credential, Eta_ai.ai_error) Eta.Effect.t
(** Deep refresh: returns the updated durable credential. *)

(** {1 Provider and Responses} *)

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

type client_identity = { originator : string; user_agent : string }

val client_identity :
  ?originator:string -> user_agent:string -> unit -> client_identity

val provider :
  ?base_url:string ->
  account_id:string ->
  identity:client_identity ->
  ?session_id:string ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.provider

val provider_for_credential :
  ?base_url:string ->
  identity:client_identity ->
  ?session_id:string ->
  ?extra_headers:Eta_ai.headers ->
  oauth_credential ->
  Eta_ai.provider

val auth_headers :
  identity:client_identity ->
  ?session_id:string ->
  ?stream:bool ->
  ?extra_headers:Eta_ai.headers ->
  account_id:string ->
  access_token:Eta_ai.api_key ->
  unit ->
  Eta_ai.headers

val auth_headers_of_credential :
  identity:client_identity ->
  ?session_id:string ->
  ?stream:bool ->
  ?extra_headers:Eta_ai.headers ->
  oauth_credential ->
  Eta_ai.headers

val encode_responses :
  ?structured_output:structured_output ->
  Eta_ai.chat_request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_responses :
  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result

val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result

val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

(** {1 Native model catalog} *)

type model_info = {
  slug : string;
  display_name : string option;
  description : string option;
  supported_in_api : bool;
  priority : int option;
  default_reasoning_level : string option;
  supported_reasoning_levels : string list;
}

val models_request :
  ?provider:Eta_ai.provider ->
  ?client_version:string ->
  identity:client_identity ->
  credential:oauth_credential ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val decode_models : Eta_ai.raw_json -> (model_info list, Eta_ai.ai_error) result

val list_models :
  ?provider:Eta_ai.provider ->
  ?client_version:string ->
  identity:client_identity ->
  Eta_http.Client.t ->
  credential:oauth_credential ->
  (model_info list, Eta_ai.ai_error) Eta.Effect.t

val responses_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  identity:client_identity ->
  ?session_id:string ->
  credential:oauth_credential ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val responses :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  identity:client_identity ->
  ?session_id:string ->
  Eta_http.Client.t ->
  credential:oauth_credential ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_responses :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  identity:client_identity ->
  ?session_id:string ->
  Eta_http.Client.t ->
  credential:oauth_credential ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

module Chat : sig
  val request :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    identity:client_identity ->
    ?session_id:string ->
    credential:oauth_credential ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    identity:client_identity ->
    ?session_id:string ->
    Eta_http.Client.t ->
    credential:oauth_credential ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    identity:client_identity ->
    ?session_id:string ->
    Eta_http.Client.t ->
    credential:oauth_credential ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end
