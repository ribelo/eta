# P2 Misuse Results

Command shape:

```text
nix develop -c ocamlc -I _build/default/lib/eta/.eta.objs/byte -c <fixture>
```

One-command runner:

```text
nix develop -c bash scratch/eta_research/let_at_and_with_resource/p2_misuse/run.sh
```

## not_cps_effect.ml

Expected: `let@` applied to an ordinary Eta effect fails clearly.

```text
File "scratch/eta_research/let_at_and_with_resource/p2_misuse/not_cps_effect.ml", line 5, characters 11-24:
5 |   let@ x = Effect.pure 1 in
               ^^^^^^^^^^^^^
Error: This expression has type "(int, 'a) Eta.Effect.t"
       but an expression was expected of type "('b -> 'c) -> 'd"
```

Result: acceptable. The error points at the non-CPS effect and says a callback-taking value was expected.

## let_star_on_cps.ml

Expected: `let*` applied to a CPS callback fails clearly.

```text
File "scratch/eta_research/let_at_and_with_resource/p2_misuse/let_star_on_cps.ml", line 7, characters 11-21:
7 |   let* x = with_thing in
               ^^^^^^^^^^
Error: This expression has type "(int -> 'a) -> 'a"
       but an expression was expected of type "('b, 'c) Eta.Effect.t"
```

Result: good. The error distinguishes CPS function shape from Eta effect shape.

## mixed_cleanup_order.ml

Expected: a confused body mixing `let@` and `let*` without returning an effect fails.

```text
File "scratch/eta_research/let_at_and_with_resource/p2_misuse/mixed_cleanup_order.ml", line 10, characters 2-7:
10 |   x + y
       ^^^^^
Error: This expression has type "int" but an expression was expected of type
         "('a, 'b) Eta.Effect.t"
```

Result: acceptable. The final actionable line is less educational than the first two fixtures, but it still points at the body returning a bare value instead of an effect.

Verdict: P2 does not disprove H-C or H-D. Error clarity is acceptable for H-C/H-D and does not force H-B/H-F.
