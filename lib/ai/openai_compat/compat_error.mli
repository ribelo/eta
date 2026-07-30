(** Lossless OpenAI-compatible adapter failures. *)

type provider_payload = Eta_ai.Json.t
(** Optional decoded response body. No provider-specific schema is asserted. *)

type t =
  | Http of Eta_http.Error.t
  | Provider of {
      provider : Eta_ai.provider_name;
      response : provider_payload Eta_ai.Provider.Error.http_response;
    }
  | Unknown_response of {
      provider : Eta_ai.provider_name;
      response : unit Eta_ai.Provider.Error.http_response;
    }
  | Provider_response of {
      provider : Eta_ai.provider_name;
      status : int option;
      payload : Eta_ai.Json.t option;
      raw_body : Eta_ai.raw_json option;
      message : string option;
      code : string option;
    }
  (** Structured provider failure without an HTTP envelope. *)
  | Decode of {
      provider : Eta_ai.provider_name;
      message : string;
      raw_body : Eta_ai.raw_json option;
    }
  | Invalid_request of {
      provider : Eta_ai.provider_name;
      message : string;
    }
  | Unsupported of {
      provider : Eta_ai.provider_name;
      feature : string;
    }
  | Invalid_tool of {
      name : string;
      message : string;
    }

val of_codec_failure :
  provider:Eta_ai.provider_name -> Eta_ai_openai_codec.codec_failure -> t

val of_ai_error : ?provider:Eta_ai.provider_name -> Eta_ai.ai_error -> t
(** Map a codec/neutral [Eta_ai.ai_error] into this nominal channel without
    inventing HTTP status or headers and without classifying local validation
    from neutral provider-error shape. *)

val of_wire_payload :
  provider:Eta_ai.provider_name ->
  ?status:int ->
  ?raw_body:Eta_ai.raw_json ->
  Eta_ai_openai_codec.wire_error_payload ->
  t

val decode :
  provider:Eta_ai.provider_name ->
  status:int ->
  headers:Eta_ai.headers ->
  Eta_ai.raw_json ->
  t

val classification : t -> string
val to_ai_error : t -> Eta_ai.ai_error
val pp : Format.formatter -> t -> unit
