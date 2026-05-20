# R-channel follow-up research

This lab answers the GPT Pro follow-up questions after the R-channel, Layer,
provide, and DX research:

- Can a black-box env-requiring effect be embedded with a different local env
  after Effect.provide was deleted?
- What public .mli shapes are readable, and where does the thunk pattern matter?
- What happens when two libraries pick the same env method with the same type but
  different semantics?
- How much downstream source churn appears when a leaf effect gains a new
  capability?

The lab is deliberately small and uses the production Effect.t / Runtime.run
surface where possible. Any local interpreter is marked as research-only.

