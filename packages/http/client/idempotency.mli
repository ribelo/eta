(** HTTP request idempotency and body replayability classification.

    The method map follows RFC 9110 section 9.2.2: GET, HEAD, PUT, DELETE,
    OPTIONS, and TRACE are idempotent. POST and PATCH are not idempotent by
    method, but callers can opt in with an Idempotency-Key header when the body
    is replayable. *)

type classification =
  | Retryable
  | Needs_idempotency_key
  | One_shot_body

val method_is_idempotent : string -> bool
val has_idempotency_key : Request.t -> bool
val body_replayable : Request.t -> bool
val classify : Request.t -> classification
val retryable : Request.t -> bool
val with_idempotency_key : string -> Request.t -> Request.t
