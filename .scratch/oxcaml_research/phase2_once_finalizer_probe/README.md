# Phase 2 Once Finalizer Probe

This lab checks whether the requested acquire_release shape can carry a release
callback at [@ once] mode without breaking the library's current reusable effect
AST.

The probe intentionally separates two claims:

- public_signature_once_call_negative.ml: the [@ once] parameter rejects a
  release callback that is called twice.
- minimal_once_acquire_reuse_negative.ml: storing that once callback in a
  reusable AST makes the whole program one-shot.
- consuming_run_once_acquire_negative.ml: making interpretation consume the AST
  still cannot extract ordinary success values from a once constructor.
- church_once_resource_candidate.ml: a one-shot interpreter-function shape can
  own and consume a once release callback.

portable_atomic_counter_positive.ml confirms the Portable.Atomic counter API
needed for daemon accounting.
