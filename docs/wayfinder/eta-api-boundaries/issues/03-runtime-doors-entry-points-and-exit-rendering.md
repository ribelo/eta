# Runtime doors: entry points and exit rendering

Type: grilling
Status: open
Blocked by: 01, 02

## Question

Which runtime-door APIs does Eta add, change, or reject, and in which
packages?

Candidates from the digest:

- A `run_main`-style CLI door. Every consumer hand-writes it: `Eio_main`,
  `Switch`, runtime create, `Cause.pp`, interrupt-only detection, and exit
  codes. Pie alone has about 15 copies in its tests.
- A run-to-result that keeps the cause on non-typed exits. `Exit.to_result`
  returns an option. On `None`, consumers call `failwith "effect failed"`
  and lose the cause. Nema has 4 such sites.
- The fate of `run_exn`, which erases typing.

For each candidate: add, change, or reject, with a named shape sketch, a
package home, and law-registry obligations. Apply the rubric from
[H-W4 decision rubric](01-hw4-decision-rubric.md). Use the prior art from
[Runtime-door prior art](02-runtime-door-prior-art.md). Cover what the door
renders on typed failure, on defect, and on interruption.
