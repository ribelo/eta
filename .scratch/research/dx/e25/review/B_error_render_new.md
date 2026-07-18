```ocaml
open Eta

type err = [ `Declined of string | `Timeout ]

let pp_error fmt = function
  | `Declined reason -> Format.fprintf fmt "declined:%s" reason
  | `Timeout -> Format.pp_print_string fmt "timeout"

let charge reason =
  Effect.with_error_pp pp_error
    (Effect.named "payment.charge"
       (Effect.fail (`Declined reason)))

let leaf reason =
  Effect.named ~error_pp:pp_error "payment.charge"
    (Effect.fail (`Declined reason))
```

Typed failure stays on the error channel. The printer is
`Format.formatter -> err -> unit` and plugs into OCaml's `pp` / `[@@deriving
show]` culture. Omission still yields `"<typed failure>"`. Render runs at most
once per span status or exception event; a raising `error_pp` becomes a defect
via the ordinary capture path.
