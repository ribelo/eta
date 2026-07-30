(** Lossless OpenAI failures. *)

type provider_payload = {
  message : string option;
  type_ : string option;
  param : Eta_ai.Json.t option;
  code : Eta_ai.Json.t option;
  (** Nested [error] object when present; otherwise the complete decoded body. *)
  raw : Eta_ai.Json.t;
  (** Complete decoded response JSON, including unknown top-level fields. *)
  full : Eta_ai.Json.t;
}

type t =
  | Http of Eta_http.Error.t
  (** eta-http transport failure. *)
  | Provider of provider_payload Eta_ai.Provider.Error.http_response
  (** Non-success HTTP response with a decodable body. *)
  | Unknown_response of unit Eta_ai.Provider.Error.http_response
  (** Non-success HTTP response whose body is not JSON. *)
  | Provider_response of {
      status : int option;
      message : string option;
      type_ : string option;
      param : Eta_ai.Json.t option;
      code : Eta_ai.Json.t option;
      raw : Eta_ai.Json.t option;
      full : Eta_ai.Json.t option;
      raw_body : Eta_ai.raw_json option;
    }
  (** Structured provider failure without an HTTP envelope: Responses
      [status=failed], midstream SSE provider errors, and explicit neutral
      projections that carry provider facts but not real response headers. *)
  | Decode of {
      message : string;
      raw_body : Eta_ai.raw_json option;
    }
  | Invalid_request of string
  | Unsupported of string
  | Invalid_tool of {
      name : string;
      message : string;
    }

val decode :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> t
(** Decode a non-success HTTP body without discarding status, headers, or body. *)

val of_wire_payload :
  ?status:int ->
  ?raw_body:Eta_ai.raw_json ->
  Eta_ai_openai_codec.wire_error_payload ->
  t
(** Map codec wire error facts into a non-HTTP {!Provider_response}. *)

val of_codec_failure : Eta_ai_openai_codec.codec_failure -> t
(** Map structured codec failure into this nominal channel without sentinel
    inference through neutral [ai_error]. *)

val of_ai_error : Eta_ai.ai_error -> t
(** Map a codec/neutral [Eta_ai.ai_error] into this nominal channel without
    inventing HTTP status or headers and without classifying local validation
    from neutral provider-error shape. Real HTTP failures must use {!decode} or
    {!Http}. *)

val classification : t -> string
(** Stable classification token for telemetry ([error.type]). *)

val to_ai_error : t -> Eta_ai.ai_error
(** Total explicit projection into the neutral [Eta_ai.ai_error] vocabulary. *)

val pp : Format.formatter -> t -> unit
