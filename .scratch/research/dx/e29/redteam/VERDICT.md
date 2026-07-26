# DX-E29 Red-team verdict

Compiled against the installed `eta` package in the OxCaml 5.2.0+ox switch
(`ocamlfind ocamlc -package eta -c <probe>.ml`). Raw compiler output is in
each `<probe>.output` file.

## Q1. Does `par3` make the nested-tuple mismatch bug class unwritable?

It was already unwritable at runtime: the typechecker rejects every
mismatch. The measured difference is what the user must decode.

| Probe | Shape | Outcome | Compiler message gist |
|---|---|---|---|
| 1 | `par (par a b) c` + flat `(x, y, z)` pattern (the natural mistake) | TYPE ERROR | `('a * 'b) * 'c` not compatible with `int * int * int` — user must discover the nesting from the message |
| 2 | `par a (par b c)` + left-nested `((x, y), z)` pattern (nesting-direction mismatch) | TYPE ERROR | `'a * 'b` not compatible with `int` — same decode burden, subtler site |
| 3 | `par3 a b c` + flat `(x, y, z)` pattern (the intended spelling) | **COMPILES** | — |
| 4 | `par3 a b c` + nested `((x, y), z)` pattern (carried-over habit) | TYPE ERROR | `'a * 'b * 'c` not compatible with `(int * int) * int` — rejected exactly as strictly as probe 1 |

The honest claim, per sealed prediction P4: `par3` adds **no new static
guarantee**. What it removes is the *invitation*: with `par3` the correct
spelling and the user's flat-triple mental model coincide, so the error
class is no longer produced in the first place. Under the status quo the
typechecker catches the bug but the error message bills the user for the
API's nesting accident. This is an ergonomics win, not a safety win, and
the report must not inflate it.

## Q2. Does `par3`/`par4` introduce any new footgun?

| Candidate | Assessment | Verdict |
|---|---|---|
| Arity temptation: user with 5 effects reaches for `par5` | `par5` does not exist; the failure is an immediate unbound-value/arity error at the application, and the `.mli` states the rule ("Arity cap is four: for five or more effects use `all` for homogeneous work or nested `par` for heterogeneous products"). Loud, documented, no silent default. | not a footgun |
| `par4` vs `all` for four homogeneous effects | Both compile and both are fail-fast concurrent; they differ only in result shape (quadruple vs list). The `.mli` rule assigns homogeneous work to `all`. A user picking the "wrong" one loses nothing semantically. | not a footgun |
| Failure-position observability | A `par3` failure cause does not name the failing position — identical to `par` and `all`; inherited, not introduced. | inherited, not new |
| Completion-order misreading | Tuple order is argument order regardless of completion order, stated in the `.mli` and pinned by the order tests; identical contract to `par`/`all`. | inherited, not new |

No new footgun class. Sealed P4 (+0 new) holds.

## Verdict

`par3` erases an ergonomics bug class the status quo repeatedly invites
(nested-vs-flat pattern mismatch and nesting-direction mismatch) without
opening any new one. Probes 1–2 are the bug the sugar treats; probe 3 is
the treated form; probe 4 proves the fence is not weakened.
