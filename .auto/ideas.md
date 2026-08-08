# Eta Signal performance ideas

## Next measurements

- Establish the five-row public baseline. Profile the worst wall-ratio row with
  release symbols and `perf`.
- Measure allocations in changed depth 1 and dynamic switching with Memtrace or
  the OxCaml zero-allocation checker before changing representation.
- Inspect the matching Incremental propagation and observer-delivery paths after
  the Eta profile identifies a specific cost.

## Candidate work after measurement

- Check the remaining generic edge plan and post-commit delivery. The Signal Map
  profile attributed visible time to this path after graph-wide scans vanished.
- Check whether `make_raw` option wrapping, duplicate-evaluation bookkeeping, or
  per-dependency listeners dominate shallow changed propagation.
- Check whether successful static passes allocate rollback journals or callback
  batches that can use OxCaml local allocation without escaping.
- Check dynamic `bind` scope creation, retirement, and topology repair for work
  that accumulates across switches.
- Use `[@zero_alloc]` on a measured leaf helper only after its transitive calls
  satisfy the checker. Do not add trusted assumptions to hide allocations.

## Retained findings

- Duplicate-dependency freshness now uses a generation-safe candidate registry.
- Successful passes without checkpoints no longer scan all graph slots to clear
  drained queues.
- Timer-free graphs bypass timer discovery and refresh planning.
- Zero or one observer bypasses dependency sorting.
- Empty stale-freshness registries bypass repair setup.
