# DX-E27 red-team verdict

The adversarial cases are registered in the shared Observability suite and pass
on the focused OxCaml/Eio run (596 tests total).

| Attack | Discriminator | Result |
| --- | --- | --- |
| Make the disabled path format | Side-effecting `%a` printer under no logger and under `Debug`/minimum `Warn` | **PASS:** zero printer calls |
| Make an intercept bypass admission | Counting interceptor around the filtered record | **PASS:** zero interceptor calls |
| Double-format an enabled record | Counting `%a` printer plus body assertion | **PASS:** exactly one call and one record |
| Drop before formatting | Counting printer followed by `Drop` | **PASS:** one printer call, zero sink calls |
| Escape ordinary defect capture | `%a` printer raises a physically checked exception | **PASS:** same exception in `Cause.Die`, zero sink calls |
| Hide eager argument work | Count an argument expression before runtime execution | **PASS:** count is already one before `run` |

Focused command:

```sh
nix develop -c dune runtest test/core_eio --force
```
