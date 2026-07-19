# DX-E7 Review Packet Manifest

The before/after labels are explicit here; the orchestrator may randomize them
when presenting the packet.

| File | Material | Provenance |
| --- | --- | --- |
| `telemetry-before.txt` | Default placeholder for `Db 7` | Real-tracer golden test |
| `telemetry-after.txt` | Derived `db:7` for the same failure | Real-tracer golden test |
| `expansion-1.ml` | Mixed nullary/built-in generated binding | `test/ppx_expansion/expected_expansions.txt` |
| `expansion-2.ml` | Custom override generated binding | `test/ppx_expansion/expected_expansions.txt` |
| `QUESTIONS.md` | Comprehension and PR-approval prompts | DX-E7 review protocol |

Reproduce the telemetry and expansion evidence with:

```sh
nix develop -c dune runtest test/ppx_eio test/ppx_expansion --force
```
