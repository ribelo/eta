# PPX env research

This lab tests whether ppx_effet should improve object-row env DX without
becoming dependency injection.

Candidates:

- P-A: baseline raw env#cap leaves.
- P-B: [%effet.sync] / [%effet.async] capability-binding leaves.
- P-C: capability profile/accessor style, written manually as the shape a
  declaration PPX would generate.
- P-D: [%effet.env] runtime boundary object builder.

The winning production additions are intentionally syntactic:

- [%effet.sync "name" (cap : Type) body]
- [%effet.async "name" (cap : Type) body]
- [%effet.env { cap = (value : Type); ... }]

They do not infer envs, wire services, create Layer/Context/Tag, or add tracer
requirements to the env row.

