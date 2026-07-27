# DX-E38 red-team cases

These cases attack the points where an existential finalizer payload can regress
silently. The executable assertions live in the normal test suites so they remain
project gates rather than scratch-only probes.

| Attack | Required observation | Executable test |
| --- | --- | --- |
| Release fails without `error_pp` | The full cause still renders `Finalizer(Fail("<typed failure>"))`. | `release failure without error_pp keeps default finalizer render` in `test/ppx_common/ppx_common_suites.ml` |
| Release fails under E7-derived `pp_err` | The full cause renders `Finalizer(Fail("db:7"))`; the derived kind and payload survive cleanup conversion. | `derived eta_error printer renders release finalizer failure` in `test/ppx_common/ppx_common_suites.ml` |
| Distinct values and hidden types share one printer output | Both equality modes report equality for the collision and inequality for a distinct rendering. This exposes the documented rule honestly: equality observes diagnostics, not hidden value identity. | `finalizer equal uses rendered form including collisions` and `finalizer diagnostic equal uses rendered form including collisions` in `test/core_common/cause_exit_common_suites.ml` |

## Outcome

All three attacks passed under the Nix/OxCaml focused gate:

```sh
nix develop -c dune runtest test/core_eio test/ppx_eio test/otel_eio test/laws --force
```

- printer-less release output remained byte-identical;
- the E7-derived printer produced `db:7` through release conversion;
- distinct hidden values/types with colliding printer output compared equal in
  both equality modes, while a distinct rendering compared unequal.

The equality limit is intentional and public: neither equality mode can recover
the existential value type, so they compare diagnostics rather than hidden value
identity.
