# DX-E27 red-team verdict

The adversarial cases are registered in the shared Observability suite and pass
on the focused OxCaml/Eio run (596 tests total).

| Attack | Discriminator | Result |
| --- | --- | --- |
| Make the disabled path format | Counting `%d` closure, `%a` printer, and `%t` thunk under no logger and `Debug`/minimum `Warn` | **PASS:** zero calls for all three |
| Hide eager built-in conversion | `%1000000d` inside a filtered formatter closure | **PASS:** zero closure calls; allocation equals ordinary filtered construction |
| Make an intercept bypass admission | Counting interceptor around the filtered record | **PASS:** zero interceptor calls |
| Double-format an enabled record | Counting `%d`, `%a`, and `%t` paths plus body assertions | **PASS:** exactly one call each and three records |
| Drop before formatting | Counting printer followed by `Drop` | **PASS:** one printer call, zero sink calls |
| Escape ordinary defect capture | `%a` printer raises a physically checked exception | **PASS:** same exception in `Cause.Die`, zero sink calls |
| Run captured work too early | Count work inside the formatter before/after disabled and enabled runs | **PASS:** 0 before and after disabled; 1 after enabled |
| Conceal retention | Weak reference to a formatter capture while the blueprint remains live | **PASS:** capture remains live |

Focused command:

```sh
nix develop -c dune runtest test/core_eio --force
```
