module Loaded = Http

let contains haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop index =
    index + n_len <= h_len
    && (String.equal needle (String.sub haystack index n_len)
       || loop (index + 1))
  in
  n_len = 0 || loop 0

let body_size_cap = 1_048_576

let expect_body_too_large label ~limit = function
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Http.Error.kind = Body_too_large { limit = actual; length }; _ }) ->
      Alcotest.(check int) (label ^ " limit") limit actual;
      Alcotest.(check bool) (label ^ " length") true (length > limit)
  | Eta.Exit.Ok body ->
      Alcotest.failf "%s accepted %d bytes" label (Bytes.length body)
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s unexpected failure: %a" label
        (Eta.Cause.pp Http.Error.pp)
        cause

let retry_response ?(headers = []) ?(release = fun () -> Eta.Effect.unit) status =
  Http.Response.make ~status ~headers
    ~body:(Http.Body.Stream.of_bytes ~release [])
    ()

let retry_client responses =
  let attempts = ref 0 in
  let request _ =
    let index = min !attempts (Array.length responses - 1) in
    incr attempts;
    Eta.Effect.pure (responses.(index) ())
  in
  ( attempts,
    Http.Client.make_for_test ~protocol:Http.Client.H1 ~request
      ~stats:(fun () ->
        Eta.Effect.pure
          {
            Http.Client.protocol = H1;
            active = 0;
            idle = 0;
            capacity = 0;
            opened = !attempts;
            released = 0;
          })
      ~shutdown:(fun () -> Eta.Effect.unit) )
