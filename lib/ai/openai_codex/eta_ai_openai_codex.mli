(** OpenAI Codex (ChatGPT subscription) Responses provider.

    Wire defaults follow the Codex CLI: Responses at
    [https://chatgpt.com/backend-api/codex/responses] with ChatGPT OAuth PKCE
    against [https://auth.openai.com]. Callers own credential storage and
    selection; this package owns credential types, codecs, header planning, and
    exchange/request builders. *)

val provider_name : string
val default_base_url : string
val default_issuer : string
val default_redirect_uri : string
val client_id : string
val default_originator : string

(** {1 Subscription OAuth credentials} *)

type oauth_credential = {
  access_token : string Eta_redacted.t;
  refresh_token : string Eta_redacted.t;
  expires_at_ms : int64 option;
  account_id : string option;
}
(** Durable ChatGPT OAuth credential. Secrets are redacted; [expires_at_ms] is
    Unix epoch milliseconds when known. *)

val oauth_credential :
  access_token:string ->
  refresh_token:string ->
  ?expires_at_ms:int64 ->
  ?account_id:string ->
  unit ->
  oauth_credential

val credential_to_json : oauth_credential -> Eta_ai.Json.t

val credential_of_json :
  Eta_ai.Json.t -> (oauth_credential, Eta_ai.ai_error) result

val credential_to_string : oauth_credential -> Eta_ai.raw_json

val credential_of_string :
  Eta_ai.raw_json -> (oauth_credential, Eta_ai.ai_error) result

val pp_credential : Format.formatter -> oauth_credential -> unit
(** Prints a diagnostic that never includes secret token values. *)

val access_api_key : oauth_credential -> Eta_ai.api_key
(** Project the access token as an [Eta_ai.api_key] for shared transport. *)

(** {1 PKCE authorization} *)

type pkce = {
  code_verifier : string;
  code_challenge : string;
  code_challenge_method : string;
}

val pkce_s256 : code_verifier:string -> pkce
(** RFC 7636 S256 challenge from a verifier. *)

val generate_code_verifier : ?nbytes:int -> (unit -> int) -> string
(** Build a URL-safe verifier using [rng ()] bytes in \[0, 255\]. *)

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
  ?state:string ->
  ?code_verifier:string ->
  ?rng:(unit -> int) ->
  unit ->
  authorize_plan
(** Plan a browser PKCE authorize URL. Does not open a browser or listen. *)

(** {1 Token exchange and refresh} *)

type token_set = {
  access_token : string;
  refresh_token : string;
  expires_in : int option;
  id_token : string option;
}

val account_id_of_jwt : string -> string option
(** Read [chatgpt_account_id] from a JWT payload claim under
    [https://api.openai.com/auth]. *)

val credential_of_token_set : ?now_ms:int64 -> token_set -> oauth_credential

val exchange_code_request :
  ?issuer:string ->
  ?client_id:string ->
  redirect_uri:string ->
  code:string ->
  code_verifier:string ->
  unit ->
  Eta_http.Request.t
(** POST [application/x-www-form-urlencoded] authorization_code exchange. *)

val refresh_request :
  ?issuer:string ->
  ?client_id:string ->
  refresh_token:string ->
  unit ->
  Eta_http.Request.t
(** POST form-urlencoded refresh_token grant (Codex/Pi wire). *)

val decode_token_response :
  Eta_ai.raw_json -> (token_set, Eta_ai.ai_error) result

val exchange_code :
  ?issuer:string ->
  ?client_id:string ->
  Eta_http.Client.t ->
  redirect_uri:string ->
  code:string ->
  code_verifier:string ->
  (token_set, Eta_ai.ai_error) Eta.Effect.t

val refresh :
  ?issuer:string ->
  ?client_id:string ->
  Eta_http.Client.t ->
  refresh_token:string ->
  (token_set, Eta_ai.ai_error) Eta.Effect.t

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

val provider :
  ?base_url:string ->
  ?account_id:string ->
  ?originator:string ->
  ?session_id:string ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.provider
(** Responses provider. Default base URL is
    [https://chatgpt.com/backend-api/codex] and path [/responses].
    [auth_headers] expects the ChatGPT access token as [api_key] and attaches
    Codex headers including optional [ChatGPT-Account-ID]. *)

val provider_for_credential :
  ?base_url:string ->
  ?originator:string ->
  ?session_id:string ->
  ?extra_headers:Eta_ai.headers ->
  oauth_credential ->
  Eta_ai.provider

val auth_headers :
  ?originator:string ->
  ?session_id:string ->
  ?account_id:string ->
  ?extra_headers:Eta_ai.headers ->
  access_token:Eta_ai.api_key ->
  unit ->
  Eta_ai.headers
(** Provider-owned Codex authorization headers. Callers pass the resolved access
    token; they do not construct [Authorization] themselves. *)

val auth_headers_of_credential :
  ?originator:string ->
  ?session_id:string ->
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

val models_request :
  ?provider:Eta_ai.provider ->
  ?client_version:string ->
  credential:oauth_credential ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result
(** GET [/models] against the Codex base URL. *)

val responses_request :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  credential:oauth_credential ->
  Eta_ai.chat_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val responses :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  credential:oauth_credential ->
  Eta_ai.chat_request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val stream_responses :
  ?structured_output:structured_output ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  credential:oauth_credential ->
  Eta_ai.chat_request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t

module Chat : sig
  val request :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    credential:oauth_credential ->
    Eta_ai.chat_request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    credential:oauth_credential ->
    Eta_ai.chat_request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream :
    ?structured_output:structured_output ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    credential:oauth_credential ->
    Eta_ai.chat_request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end
