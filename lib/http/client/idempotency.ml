module Header = Header

type classification =
  | Retryable
  | Needs_idempotency_key
  | One_shot_body

let method_is_idempotent method_ =
  match String.uppercase_ascii method_ with
  | "GET" | "HEAD" | "PUT" | "DELETE" | "OPTIONS" | "TRACE" -> true
  | _ -> false

let has_idempotency_key request =
  match Header.get "idempotency-key" request.Request.headers with
  | Some value -> String.trim value <> ""
  | None -> false

let body_replayable request =
  match request.Request.body with
  | Empty | Fixed _ | Rewindable_stream _ -> true
  | Stream _ -> false

let classify request =
  if not (body_replayable request) then One_shot_body
  else if method_is_idempotent request.Request.method_ || has_idempotency_key request
  then Retryable
  else Needs_idempotency_key

let retryable request =
  match classify request with Retryable -> true | _ -> false

let with_idempotency_key key (request : Request.t) =
  {
    request with
    Request.headers =
      request.headers
      |> Header.remove "idempotency-key"
      |> Header.unsafe_add "Idempotency-Key" key;
  }
