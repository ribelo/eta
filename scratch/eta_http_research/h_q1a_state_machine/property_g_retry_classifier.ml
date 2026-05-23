open Generators

let seed = 47_007
let trials = 300

type outcome = Http of int | Connect | Decode | Tls_cert

let random_outcome rng =
  match Random.State.int rng 7 with
  | 0 -> Http 500
  | 1 -> Http 429
  | 2 -> Http 408
  | 3 -> Http 404
  | 4 -> Connect
  | 5 -> Decode
  | _ -> Tls_cert

let error_of_outcome = function
  | Http status ->
      Error.make ~protocol:Error.H2 ~method_:"GET" ~uri:"https://example.test"
        (HTTP_status { status; headers = [] })
  | Connect ->
      Error.make ~protocol:Error.H2 ~method_:"GET" ~uri:"https://example.test"
        (Connect_timeout { timeout_ms = Some 100 })
  | Decode ->
      Error.make ~protocol:Error.H2 ~method_:"GET" ~uri:"https://example.test"
        (Decode_error { codec = "gzip"; message = "crc" })
  | Tls_cert ->
      Error.make ~protocol:Error.H2 ~method_:"GET" ~uri:"https://example.test"
        (Tls_certificate_error { reason = Expired; message = "expired" })

let expected_retry = function
  | Http (408 | 429 | 500) -> true
  | Http status when status >= 501 && status <= 599 -> true
  | Connect -> true
  | Http _ | Decode | Tls_cert -> false

let adapter_retry outcome =
  match Error.retryability (error_of_outcome outcome) with
  | Retryable | Retryable_if_body_replayable -> true
  | Not_retryable -> false

let run () =
  let rng = Random.State.make [| seed |] in
  let retryable = ref 0 in
  let failure = ref None in
  for _ = 1 to trials do
    let outcome = random_outcome rng in
    if expected_retry outcome then incr retryable;
    if adapter_retry outcome <> expected_retry outcome then failure := Some []
  done;
  {
    name = "property_g_retry_classifier_matches_h_d_errors";
    seed;
    trials;
    coverage = [ ("retryable_outcomes", !retryable) ];
    shrunk_failure = !failure;
  }
