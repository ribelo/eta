# LadybugDB Extension Lifecycle Evidence

Question: should eta_ladybug expose extension helpers, or should callers keep
using raw Connection.exec statements?

Proof obligations:

- identify LadybugDB's real extension syntax and implementation path;
- verify at least one positive local LOAD EXTENSION with a real dynamic
  .lbug_extension;
- verify official INSTALL plus LOAD EXTENSION against a real extension repo
  without baking network access into the default test suite;
- verify negative behavior for missing local and missing installed official
  extensions;
- avoid adding a wrapper that only renames raw Cypher without typed values or
  runtime coverage.

Verdict: implement explicit helpers. The C ABI has no extension-specific entry
points, but LadybugDB exposes first-class extension statements, WAL logging, and
typed listing functions through the query engine.
