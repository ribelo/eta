```ocaml
open Eta

type err = [ `Declined of string | `Timeout ]

let render_error = function
  | `Declined reason -> "declined:" ^ reason
  | `Timeout -> "timeout"

let charge reason =
  Effect.with_error_renderer render_error
    (Effect.named "payment.charge"
       (Effect.fail (`Declined reason)))

let leaf reason =
  Effect.named ~error_renderer:render_error "payment.charge"
    (Effect.fail (`Declined reason))
```

Typed failure stays on the error channel. The renderer is `err -> string`.
Omission of the renderer yields the default `"<typed failure>"` span status.
A raising renderer previously closed spans with `"<error renderer raised>"`
while preserving the original typed failure.
