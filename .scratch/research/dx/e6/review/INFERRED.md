# Inferred Review Surface

Both review candidates infer the same lifecycle boundary:

```ocaml
val boot :
  (services -> ('a, 'err) Eta.Effect.t) -> ('a, 'err) Eta.Effect.t
```

The individual release functions infer independent error rows, but none appears
in `boot`'s result type. This was checked against the branch build with
`ocamlc -i` for both `boot-old.ml` and `boot-new.ml`; their inferred `boot`
signatures are identical.
