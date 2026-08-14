# Module replacement and rollback

Type: prototype
Status: claimed
Blocked by: 02, 07, 12, 16

## Question

What HMR contract can replace affected component declarations transactionally
on native Eta?

Prototype dependency classification, stale-entry detection, component
replacement, load failure, and restoration of the previous declarations.
Separate code loading from component replacement.

Preserve serialized generations within one component instance. Decide whether a
replacement transaction uses a distinct candidate instance that can become
discoverable while the old provider episode drains.

Component-local state does not migrate. The answer must state what remains
loaded after rollback and what machine-code or module artifacts native OCaml
cannot unload.
