# eta_component surface completions

Type: grilling
Status: open
Blocked by:

## Question

Which surface gaps in the shipped `eta_component` package get completed?

This is a batch of small decisions. Each item is add, change, or reject,
with a one-line shape note and any law-registry obligation:

- Printers: `pp` for `Context.admission_error` (15 variants),
  `Diagnostics.phase`, `integrity`, `lifecycle`, `progress`, and
  `Fence.outcome` and `kind`. Pie hand-wrote all of these.
- Expose `Entry_id.to_string`. It exists in the `.ml` and is hidden by the
  `.mli`. Pie uses `Format.asprintf "%a" Entry_id.pp` as a Hashtbl key.
  Consider `Map` and `Set` support too.
- Close the hole between `Replacement.target`, which requires a
  `Target_revision.t`, and `Diagnostics.target_revision`, which returns an
  option. Pie used `Obj.magic` to cross it.
- A `reconcile_and_await` convenience for the fence two-step.
- Diagnostics as a stream, to replace hand-rolled poll loops.
- The `Activation.own` ceremony for no-release components.

The loader specs stay out of this ticket. They live in
`docs/issues/eta-component-runtime/` and address source-to-admission
orchestration, not declaration ergonomics.
