# Observability bootstrap

Type: grilling
Status: open
Blocked by: 01

## Question

What observability bootstrap does Eta add, change, or reject?

Candidates from the digest:

- An env-driven, one-call OTLP init. `Eta_otel.create` needs a runtime
  factory, an HTTP client, a clock, a host, and a port. Pie and grip contain
  near-identical 120-line copy-pasted bootstraps. Exergy wrote its own.
  Decide the package home: `eta_otel`, or a new package such as
  `eta_otel_env`.
- Annotate sugar and discovery. `annotate_all` exists, but consumers fold
  single `annotate` calls themselves.
- Spans around synchronous work. Nema wraps sync code in an effect on a
  separate "maintenance runtime" to get spans.

For each candidate: add, change, or reject, with a named shape sketch, a
package home, and law-registry obligations. Apply the rubric from
[H-W4 decision rubric](01-hw4-decision-rubric.md).
