module Header = Header

type classification =
  | Retryable
  | Needs_idempotency_key
  | One_shot_body

let method_is_idempotent method_ =
  match Method.of_string method_ with
  | `GET | `HEAD | `PUT | `DELETE | `OPTIONS | `TRACE -> true
  | `POST | `PATCH | `CONNECT | `Other _ -> false

let[@zero_alloc] has_non_trim_space value =
  let len = String.length value in
  let index = ref 0 in
  let found = ref false in
  while (not !found) && !index < len do
    found :=
      not (Eta.String_helpers.is_trim_space (String.unsafe_get value !index));
    incr index
  done;
  !found

let has_idempotency_key request =
  match Header.get "idempotency-key" request.Request.headers with
  | Some value -> has_non_trim_space value
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
