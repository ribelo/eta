(** Exa API request planning and raw-response execution. *)

type api_key = string Eta_redacted.t

val api_key : string -> api_key

type operation =
  | Search of string
  | Contents of string
  | Code_context of string
  | Agent_create of string
  | Agent_get of { id : string }
  | Agent_list of { limit : int option; cursor : string option }
  | Agent_cancel of { id : string }
  | Agent_events of {
      id : string;
      limit : int option;
      cursor : string option;
      last_event_id : string option;
    }
(** JSON-body operations carry already-encoded JSON. Callers retain ownership of
    provider-specific input types while Eta owns Exa authentication, endpoint
    mapping, URL encoding, and HTTP interpretation. *)

type response = {
  status : int;
  headers : Eta_http.Core.Header.t;
  body : string;
}

type error = Invalid_request of string | Http of Eta_http.Error.t

val max_response_body_bytes : int
val error_message : error -> string

val request :
  ?base_url:string -> api_key:api_key -> operation ->
  (Eta_http.Request.t, error) result
(** Build an Exa request. The default base URL is [https://api.exa.ai]. *)

val run :
  ?base_url:string ->
  Eta_http.Client.t ->
  api_key:api_key ->
  operation ->
  (response, error) Eta.Effect.t
(** Execute one request and consume at most {!max_response_body_bytes}. HTTP
    statuses, including non-2xx statuses, are returned as response data. *)
