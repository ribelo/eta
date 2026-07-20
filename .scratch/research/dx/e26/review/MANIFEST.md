# DX-E26 review packet

- `worker-spawn-old.ml` — realistic worker lifecycle with an application-owned
  atomic counter, formatting, and implicit process-global reset policy.
- `worker-spawn-new.ml` — the same lifecycle using the active runtime's
  `Effect.fresh_named` counter.
- `QUESTIONS.md` — answers to the two boundary questions reviewers should ask.

Review focus: the new call site intentionally removes counter ownership from the
application only when runtime-local identity is the desired scope. It is not a
replacement for globally namespaced identifiers.
