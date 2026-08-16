# H-W4 decision rubric

Type: grilling
Status: open
Blocked by:

## Question

Decide the written rubric that every candidate ticket in this map applies
when it judges wrap, bridge, recipe, or reject.

The rubric must answer:

- When does a repeated consumer pattern earn an Eta wrapper? Start from the
  H-W4 invariant list: typed failure preservation, cancellation cleanup,
  scoped lifecycle, close fences, backpressure ownership, mode and
  portability fences, and runtime observability.
- When is the answer a `from_eio_X` bridge that exposes Eio directly?
- When is the answer a documented recipe instead of code?
- When is the answer rejection, and what records the rejection?
- What weight does "N consumers reinvented it" carry? The digest warns that
  reinvention alone is not proof.
- How does the rubric pick a package home under the package boundary policy?
- Does the rubric differ between boundary APIs and ergonomics APIs?

Use `$codebase-design` for the deep-module test: a good wrapper owns an
invariant, and a shallow wrapper only adds vocabulary.
