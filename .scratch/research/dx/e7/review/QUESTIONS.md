# DX-E7 Review Questions

1. Would you approve `expansion-1.ml` and `expansion-2.ml` verbatim in an OCaml
   pull request? If not, identify the generated line that should change.
2. Is `pp_err` wired into Eta spans automatically, or must the caller pass it
   through `?error_pp` / `Effect.with_error_pp`?
3. What happens when a payload type is not one of the five built-ins and the tag
   has no `[@eta.render f]`?
4. What does a raising built-in or custom payload printer become at runtime?
5. Is the change from `Db_down` to `Database_down` telemetry-compatible?
