(** Lossless xAI failures. *)

type provider_payload = {
  message : string option;
  code : string option;
  type_ : string option;
  param : Eta_ai.Json.t option;
  (** The provider payload itself: the nested [error] object when present,
      otherwise the complete decoded response object. *)
  raw : Eta_ai.Json.t;
}

type t =
  | Http of Eta_http.Error.t
  | Provider of {
      status : int;
      headers : Eta_ai.headers;
      payload : provider_payload;
      raw_body : Eta_ai.raw_json;
    }
  | Unknown_response of {
      status : int;
      headers : Eta_ai.headers;
      raw_body : Eta_ai.raw_json;
    }
  | Decode of {
      message : string;
      raw_body : Eta_ai.raw_json option;
    }
  | Invalid_request of string

val decode :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> t
(** Decode a non-success response without discarding status, headers, or body. *)

val to_ai_error : t -> Eta_ai.ai_error
(** Explicit provider-neutral projection.

    Lossless provider bodies remain available as the [raw] field of the
    projected [Eta_ai.Provider_error].
    [Eta_ai.project_ai_error] deliberately excludes those bodies from its
    bounded diagnostic. Local validation projects as a provider
    [invalid_request] failure, never as feature unavailability. *)

val pp : Format.formatter -> t -> unit
