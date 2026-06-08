# H-D2a Request API Sketch

Question: can eta-http hide protocol selection at the request layer while keeping the underlying h1 and h2 lifetimes correct?

Public surface proved here:

```ocaml
val request : Client.t -> Request.t -> (Response.t, error) Effect.t
```

`Response.t` exposes `status`, `headers`, `body : Stream.t`, and deferred `trailers`. The caller consumes or discards `Response.body` through the same `Stream` module for both protocols.

## Shape

- `request_api.mli` is the sketched public surface.
- `h1_internal.ml` uses `Eta.Pool` and holds the checked-out connection in an owner fiber until the response body stream releases it.
- `h2_internal.ml` uses the H-D1 multiplexer and the new `Multiplexer.request_open` stream handle so the stream permit remains active until response body release.
- `caller_demo.ml` is the single caller path used for h1 and h2. It performs a small GET, streaming POST, response-streaming read+discard, and cancellation mid-body without reading `Client.protocol`.
- `fixtures.ml` runs the same caller against both clients, checks identical traces, checks open-body active counters, and checks H-D5 remains available as a scratch private library.

## Reused Scratch Proofs

- H-D1: `Multiplexer.request_open` returns a releasable stream handle while preserving the existing eager `Multiplexer.request` helper.
- H-D5: `h_d5_alpn_bootstrap` is now a private scratch library; H-D2a links it and re-runs a dispatcher smoke proof.
- H-D-Errors: H-D2a uses `Error.t` as its typed failure payload.

## Out Of Scope

- Cookies and implicit header storage.
- HTTP/1.1 pipelining.
- Real sockets or TLS.
- A production shutdown API beyond the scratch `Client.shutdown` used to make daemon lifetimes finite in fixtures.
