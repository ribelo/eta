# Research Archive

This directory is the tracked research lane for Eta. It preserves research
bundles that should survive across machines and commits: notes, evidence,
journals, result snapshots, and buildable experiment source.

This is not project documentation. Durable user-facing docs and package ADRs
belong under `docs/` or `lib/<package>/docs/`. Those docs may cite tracked
research here as provenance, but they should stand on their own as
documentation.

The rest of `.scratch/` is local scratch space. Keep generated build output,
opam switches, third-party checkouts, downloaded source trees, and throwaway
logs outside `.scratch/research/` unless they are intentionally curated as part
of a preserved research bundle.

If a research experiment needs Dune, keep it as a separate Dune project under
this tree and build it explicitly with `dune build --root <path> ...`. Research
projects are not part of the main repository Dune workspace.
