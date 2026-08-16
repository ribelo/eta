# HTTP client ergonomics

Type: grilling
Status: open
Blocked by: 01

## Question

Which HTTP client ergonomics belong in `eta_http`, and which stay in
application code?

Candidates from the digest:

- A simple-request door: client make, `Request.make`, headers, 2xx check,
  `Body.Stream.read_all`, and error mapping. Three consumers wrote the same
  50 lines.
- A `Url` builder with a query API. `Eta_http.Url` is parse-only today.
  Taumel hand-rolled encoding through JS `encodeURIComponent`. Exergy built
  a whole package whose synopsis is "URL encoding and joining".
- A coarse `Error.category` over the 25 `Error.kind` variants. Nema wrote a
  25-case mapper. Inn substring-greps the rendered cause text for
  `"Connect_error"`.

For each candidate: add, change, or reject, with a named shape sketch, a
package home, and law-registry obligations. Apply the rubric from
[H-W4 decision rubric](01-hw4-decision-rubric.md).
