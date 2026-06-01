(** Typed eta-http client errors. *)

type protocol = H1 | H2 | Unknown

type layer =
  | Tcp
  | Tls
  | Alpn
  | Pool
  | Http_request
  | Http_response
  | Body_decode
  | Cancellation

type retryability =
  | Retryable
  | Retryable_if_body_replayable
  | Not_retryable

type tls_stage = Tls_handshake | Alpn_negotiation

type certificate_reason =
  | Expired
  | Name_mismatch
  | Untrusted_chain
  | Revoked
  | Certificate_policy_error of string

type kind =
  | Dns_error of { host : string; message : string }
  | Connect_error of { message : string }
  | Connect_timeout of { timeout_ms : int option }
  | Tls_handshake_error of { stage : tls_stage; message : string }
  | Tls_certificate_error of { reason : certificate_reason; message : string }
  | Connection_closed of { during : layer }
  | Pool_shutdown
  | Pool_acquire_timeout of { timeout_ms : int option }
  | Response_header_timeout of { timeout_ms : int option }
  | Response_body_idle_timeout of { timeout_ms : int option }
  | Total_request_timeout of { timeout_ms : int option }
  | HTTP_status of { status : int; headers : (string * string) list }
  | Decode_error of { codec : string; message : string }
  | Body_too_large of { limit : int; length : int }
  | Connection_protocol_violation of { kind : string; message : string }
  | Hpack_decode_overflow of { decoded_bytes : int; limit_bytes : int }
  | Continuation_flood of {
      accumulated_bytes : int;
      limit_bytes : int;
      frames : int;
    }
  | Stream_admission_rejected of { limit : int }
  | Rst_rate_exceeded of { observed_per_second : int; limit_per_second : int }
  | Ping_rate_exceeded of { observed_rate_hz : int; limit_hz : int }
  | Settings_churn_rate_exceeded of {
      observed_rate_hz : int;
      limit_hz : int;
    }
  | Response_header_change_rate_exceeded of {
      observed_rate_hz : int;
      limit_hz : int;
    }
  | Header_invalid of { reason : string }

type context = {
  method_ : string;
  uri : string;
  protocol : protocol;
}

type t = {
  context : context;
  kind : kind;
}

val make : ?protocol:protocol -> method_:string -> uri:string -> kind -> t
val protocol_to_string : protocol -> string
val layer_to_string : layer -> string
val retryability_to_string : retryability -> string
val kind_name : kind -> string
val layer : t -> layer
val retryability : t -> retryability
val status : t -> int option
val status_class : t -> string option
val error_class : t -> string
val headers : t -> (string * string) list
val pp : Format.formatter -> t -> unit
val to_string : t -> string
